#!/usr/bin/env python3

"""
Test live server and live desktop ISO integration with cloud-init user-data


Test procedure:
1. Check latest live server or desktop manfist
2. If manifest differs from locally cached manifest file, download new ISO
3. Create a passwordless ssh rsa key: ci_test_kvm_key
4. In a tmpdir: create cloud_localds seed iso with autoinstall user data
5. Create a QEMU target disk to represent the target VM harddrive
6. Launch QEMU KVM with seed.iso and disk providing 'autoinstall' kernel param
7. Once installed system powers down, relaunch the target disk and expose ssh
   on an open port >= 2222
8. Use ssh andkey from step 3 to validate both ephemeral boot and firt boot
   runs of cloud-init via log scrapes and cloud-init status.


Interim test solution until we grow qemu-kvm support direct in
https://github.com/canonical/pycloudlib.
"""

import argparse
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from enum import Enum
from functools import wraps
from pathlib import Path
from typing import List, Optional, Tuple
import yaml

import requests

SSH_PRIVATE_KEY_NAME = "ci_test_kvm_key"


class InstallFlavor(Enum):
    DESKTOP = "desktop"
    LIVE_SERVER = "live-server"


class UbuntuRelease(Enum):
    mantic = "23.10"
    lunar = "23.04"
    kinetic = "22.10"
    jammy = "22.04"
    focal = "20.04"
    bionic = "18.04"
    xenial = "16.04"


def retry(exception, retry_sleeps):
    """Decorator to retry on exception for retry_sleeps.

    @param retry_sleeps: List of sleep lengths to apply between
       retries. Specifying a list of [0.5, 1] tells subp to retry twice
       on failure; sleeping half a second before the first retry and 1 second
       before the second retry.
    @param exception: The exception class to catch and retry for the provided
       retry_sleeps. Any other exception types will not be caught by the
       decorator.
    """

    def wrapper(f):
        @wraps(f)
        def decorator(*args, **kwargs):
            sleeps = retry_sleeps.copy()
            while True:
                try:
                    return f(*args, **kwargs)
                except exception as e:
                    if not sleeps:
                        raise e
                    retry_msg = " Retrying %d more times." % len(sleeps)
                    logging.debug(str(e) + retry_msg)
                    time.sleep(sleeps.pop(0))

        return decorator

    return wrapper


def get_or_create_rsa_key(private_key_path: Path) -> Tuple[Path, Path]:
    """Returns a Paths of the created private key and pubkey.

    When private key doesn't exist, create a passwordless key for testing.
    """
    if not private_key_path.exists():
        subprocess.check_output(
            ["ssh-keygen", "-t", "rsa", "-f", str(private_key_path), "-N", ""]
        )
    return private_key_path, Path(f"{private_key_path}.pub")


class KVMInstance:
    def __init__(
        self, name: str, ip: str, ssh_port: str, username: str, private_key: Path
    ):
        self.name = name
        self.ip = ip
        self.ssh_port = ssh_port
        self.username = username
        self.private_key = private_key

    @retry(subprocess.CalledProcessError, [10] * 50)
    def wait_for_cloud_init(self) -> dict:
        cmd = ["cloud-init", "status", "--wait", "--format=json"]
        return json.loads(self.execute(cmd).decode())

    def execute(self, cmd: List[str]) -> bytes:
        """SSH to KVM instance, run the cmd and return the response"""
        cmd = [
            "ssh",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-i",
            str(self.private_key),
            f"{self.username}@{self.ip}",
            "-p",
            str(self.ssh_port),
            "--",
        ] + cmd
        return subprocess.check_output(cmd)

    def get_file(self, remote_path: str) -> str:
        """Read remote file content from KVMInstance"""
        logging.info(f"READ: {self.username}@{self.ip}[{self.ssh_port}]:{remote_path}")
        resp = self.execute(["sudo", "cat", remote_path])
        return resp.decode()

    def shutdown(self):
        resp = self.execute(["sudo", "shutdown", "-h", "now"])


def cloud_localds(
    tmpdir: Path,
    user_data: str,
    meta_data: str,
    vendor_data: Optional[str] = None,
    network_config: Optional[str] = None,
) -> Path:
    """Create a CIDATA disk image containing NoCloud meta-data/user-data

    This image can be mounted as a disk in qemu-kvm to provide #cloud-config
    """

    img_path = tmpdir.joinpath("my-seed.img")
    ud_path = tmpdir.joinpath("user-data")
    md_path = tmpdir.joinpath("meta-data")
    cmd = ["cloud-localds", img_path, ud_path, md_path]
    ud_path.write_text(user_data)
    md_path.write_text(meta_data)
    if vendor_data:
        tmpdir.joinpath("vendor-data").write_text(vendor_data)
        cmd += ["-v", tmpdir.joinpath("vendor-data")]
    if network_config:
        tmpdir.joinpath("network-config").write_text(network_config)
        cmd += ["-N", tmpdir.joinpath("network-config")]
    subprocess.run(cmd)
    return img_path


def create_qemu_disk(tmpdir: Path, vm_name: str, size: str):
    img_path = tmpdir.joinpath(f"{vm_name}.img")
    if img_path.exists():
        logging.debug("Reusing %s", img_path)
    else:
        subprocess.run(["truncate", "-s", size, img_path])
    return img_path


def get_release_iso(
    distro: str,
    release: str,
    flavor: InstallFlavor = InstallFlavor.LIVE_SERVER,
    arch: Optional[str] = "amd64",
    local_images_dir: Optional[str] = "/srv/iso",
) -> Path:
    if flavor == InstallFlavor.LIVE_SERVER:
        flavor_subdir = "ubuntu-server/"
    else:
        flavor_subdir = ""
    if release == "mantic":
        base_name = f"{release}-{flavor.value}-{arch}"
        iso_base_url = f"https://cdimage.ubuntu.com/{flavor_subdir}daily-live/pending/"
    else:
        base_name = f"ubuntu-{UbuntuRelease[release].value}-{flavor.value}-{arch}"
        iso_base_url = f"https://releases.ubuntu.com/{release}/"
    manifest_url = f"{iso_base_url}{base_name}.manifest"
    iso_url = f"{iso_base_url}{base_name}.iso"
    iso_path = Path(f"{local_images_dir}/{release}/{base_name}.iso")
    manifest_path = Path(f"{local_images_dir}/{release}/{base_name}.manifest")
    manifest_sum = b"ABSENT"
    iso_path.parent.mkdir(parents=True, exist_ok=True)
    if manifest_path.exists():
        p = subprocess.run(["md5sum", manifest_path], capture_output=True)
        manifest_sum = p.stdout
    r = requests.get(manifest_url, allow_redirects=True)
    manifest_path.write_bytes(r.content)
    if iso_path.exists():
        logging.info(f"Checking md5sum of {manifest_path} for stale local ISO.")
        p = subprocess.run(["md5sum", manifest_path], capture_output=True)
        if p.stdout == manifest_sum:
            logging.info(f"Using cached {iso_path} no manifest changes.")
            return iso_path
    logging.info(f"Downloading {iso_url} to {iso_path}...")
    with requests.get(iso_url, stream=True) as r:
        total_len = int(r.headers.get("Content-Length"))
        r.raise_for_status()
        total_chunks = total_len / 8192
        print_step = total_chunks // 25
        with open(iso_path, "wb") as stream:
            for idx, chunk in enumerate(r.iter_content(chunk_size=8192)):
                if idx % print_step == 0:
                    print(
                        f"{idx/print_step * 4}%"
                        f" of {total_len/1024/1024/1000:.2f}GB downloaded",
                        flush=True,
                    )
                stream.write(chunk)
    return iso_path


def extract_kernel_initrd_from_iso(tmpdir: Path, iso_path: Path) -> Tuple[Path, Path]:
    """Mount iso_path in tmpdir and extract vmlinuz and initrd to tmpdir."""
    mnt_path = tmpdir.joinpath("mnt")
    mnt_path.mkdir()
    try:
        subprocess.check_call("command -v bsdtar", shell=True)
    except Exception:
        raise RuntimeError(
            "Could not find bsdtar: sudo apt install libarchive-tools"
        )
    cmd = f"bsdtar -x -f {iso_path} casper"
    logging.info(f"Running: {cmd}")
    kernel_path = tmpdir.joinpath("vmlinuz")
    initrd_path = tmpdir.joinpath("initrd")
    subprocess.run(cmd.split(), capture_output=True)
    shutil.copy("./casper/vmlinuz", kernel_path)
    shutil.copy("./casper/initrd", initrd_path)
    shutil.rmtree("casper", ignore_errors=True)
    return (kernel_path, initrd_path)


def get_open_port(start_port: int = 2222, end_port: int = 8000) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        for port in range(start_port, end_port):
            result = sock.connect_ex(("localhost", port))
            if result != 0:
                return port
    return 2222


def stream_cmd_stdout(cmd):
    process = subprocess.Popen(cmd, shell=False, stdout=subprocess.PIPE)
    stdout_lines = []
    while True:
        output = process.stdout.readline()
        if process.poll() is not None:
            break
        if output:
            stdout_lines.append(output.decode())
            print(stdout_lines[-1], end="", flush=True)
    return "".join(stdout_lines)


def launch_kvm(
    vm_name: str,
    tmpdir: Path,
    ram_size: str,
    disk_img_path: Path,
    ssh_port: int,
    private_key: Path,
    username: str = "ubuntu",
    iso_path: Optional[Path] = None,
    seed_path: Optional[Path] = None,
    kernel_cmdline: Optional[str] = "",
    cmdline: Optional[list] = None,
) -> KVMInstance:
    """use qemu-kvm to setup and launch a test VM with optional kernel params"""
    cmd = [
        "kvm",
        #        "-no-reboot",
        "-name",
        vm_name,
        "-m",
        ram_size,
        "-drive",
        f"file={disk_img_path},format=raw,if=virtio",
        "-net",
        "nic",
        "-D",
        str(tmpdir.joinpath("qemu.log")),
    ]
    logging.info(
        f"KVM boot {vm_name}: ssh -i {private_key} {username}@localhost -p {ssh_port}"
    )
    cmd += [
        "-net",
        f"user,hostfwd=tcp::{ssh_port}-:22",
    ]
    if iso_path:
        cmd += ["-cdrom", str(iso_path)]
    if seed_path:
        cmd += ["-drive", f"file={seed_path},format=raw,if=ide"]
    if kernel_cmdline:
        assert iso_path is not None
        # Mount and extract kernel and initrd from iso
        (kernel_path, initrd_path) = extract_kernel_initrd_from_iso(tmpdir, iso_path)
        cmd += [
            "-kernel",
            str(kernel_path),
            "-initrd",
            str(initrd_path),
            "-append",
            str(kernel_cmdline),
        ]
    if cmdline:
        cmd += cmdline
    if "-daemonize" not in cmd:
        cmd.append("-nographic")
        run_cmd = stream_cmd_stdout
    else:
        run_cmd = subprocess.check_output
    logging.info(f"Running: {' '.join(cmd)}")
    try:

        resp = run_cmd(cmd)
    except subprocess.CalledProcessError as e:
        logging.error(
            f"Failed to launch {iso_path} Live installer image in"
            f" kvm with autoinstall user-data. {e}"
        )
        qemu_log = tmpdir.joinpath("qemu.log")
        if qemu_log.exists():
            logging.error(f"--- qemu.log:\n{qemu_log.read_text()}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Unknown error: {e}")
        sys.exit(1)
    logging.debug(f"Boot console:\n{resp}")
    return KVMInstance(vm_name, "127.0.0.1", ssh_port, username, private_key)


USER_DATA = """
#cloud-config
password: passw0rd
ssh_pwauth: True
users:
- default
- name: ephemeral
  ssh_import_id: [chad.smith]
  sudo: ALL=(ALL) NOPASSWD:ALL
  shell: /bin/bash
"""

USER_DATA_AUTOINSTALL = (
    USER_DATA
    + """
autoinstall:
  version: 1
  user-data:
    users:
    - default
    chpasswd: {{ expire: False }}
    ssh_pwauth: True
    hostname: target-test
    ssh_import_id: [chad.smith]
    password: passw0rd
    ssh_authorized_keys:
    - {kvm_pub_key_content}
  shutdown: poweroff
"""
)


def log_errors_and_warnings(log_content: str) -> bool:
    """Log any specific errors, and log warnings or Traceback counts"""

    error_logs = re.findall("CRTIICAL.*", log_content) + re.findall(
        "ERROR.*", log_content
    )
    if error_logs:
        logging.error(
            f"/var/log/cloud-init.log has the following errors:\n{''.join(error_logs)}"
        )
    warn_logs = [
        l
        for l in re.findall("WARN.*", log_content)
        if "Used fallback datasource" not in l
    ]
    if warn_logs:
        logging.warning(
            f"/var/log/cloud-init.log: Found {len(warn_logs)} unexpected warnings:"
            + "\n".join(warn_logs)
        )
    traceback_count = log_content.count("Traceback")
    if traceback_count:
        logging.warning(
            f"/var/log/cloud-init.log: Found {traceback_count} unexpected Tracebacks"
        )
    return any([error_logs, warn_logs, traceback_count])


def main(args):
    if args.image_type == "server":
        image_type = InstallFlavor.LIVE_SERVER
        vm_name = "ci-test-kvm-live-server-ephemeral-1"
        ram_size = "3G"
    else:
        vm_name = "ci-test-kvm-live-desktop-ephemeral-1"
        image_type = InstallFlavor.DESKTOP
        ram_size = "8G"
    with tempfile.TemporaryDirectory() as tmpdir:
        tdir = Path(tmpdir)
        private_key, pub_key = get_or_create_rsa_key(Path(SSH_PRIVATE_KEY_NAME))
        pub_key_content = pub_key.read_text().rpartition(" ")[0]
        user_data = USER_DATA_AUTOINSTALL.format(kvm_pub_key_content=pub_key_content)
        seed_path = cloud_localds(tdir, user_data, meta_data="")
        disk_img_path = create_qemu_disk(tdir, vm_name, "20G")
        iso_path = get_release_iso(
            "ubuntu",
            args.series,
            image_type,
            "amd64",
            local_images_dir=args.local_images_dir,
        )
        ssh_port = get_open_port()
        kvm1 = launch_kvm(
            vm_name=vm_name,
            tmpdir=tdir,
            ram_size=ram_size,
            iso_path=iso_path,
            seed_path=seed_path,
            disk_img_path=disk_img_path,
            ssh_port=ssh_port,
            username="ephemeral",
            private_key=private_key,
            kernel_cmdline="console=ttyS0 autoinstall",
        )
        vm_name = vm_name.replace("ephemeral", "firstboot")
        kvm2 = launch_kvm(
            vm_name=vm_name,
            tmpdir=tdir,
            ram_size=ram_size,
            disk_img_path=disk_img_path,
            ssh_port=ssh_port,
            username="ubuntu",
            private_key=private_key,
            cmdline=["-daemonize"],
        )
        time.sleep(30)
        ci_status = kvm2.wait_for_cloud_init()
        print("===== Validate ephemeral boot state =====")
        ephemeral_boot_log = kvm2.get_file("/var/log/installer/cloud-init.log")
        log_errors_and_warnings(ephemeral_boot_log)
        with open("ephemeral-cloud-init.log", "w") as stream:
            stream.write(ephemeral_boot_log)
        print("===== Validate first boot state =====")
        status_long = str(kvm2.execute(["cloud-init", "status", "--long"]))
        assert "boot_status_code: disabled-by-marker-file" in status_long
        assert "target-test" in str(kvm2.execute(["hostname"]))
        disabled_file = kvm2.get_file("/etc/cloud/cloud-init.disabled")
        assert "Disabled by Ubuntu live installer" in disabled_file
        assert ci_status["errors"] == [], "Unexpected errors:" + " ".join(
            ci_status["errors"]
        )
        first_boot_log = kvm2.get_file("/var/log/cloud-init.log")
        with open("first-boot-cloud-init.log", "w") as stream:
            stream.write(first_boot_log)
        userdata = yaml.safe_load(
            kvm2.execute(["sudo", "cloud-init", "query", "userdata"]).decode()
        )
        kvm2.shutdown()
        if log_errors_and_warnings(first_boot_log):
            sys.exit(1)
        if log_errors_and_warnings(first_boot_log):
            sys.exit(1)
        assert ci_status["datasource"] == "none"
        assert ci_status["boot_status_code"] == "disabled-by-marker-file"
        assert sorted(
            [
                "chpasswd",
                "growpart",
                "hostname",
                "locale",
                "password",
                "resize_rootfs",
                "ssh_authorized_keys",
                "ssh_import_id",
                "ssh_pwauth",
                "users",
                "write_files",
            ]
        ) == sorted(userdata.keys())
        print(
            "SUCCESS: cloud-init disabled on first boot, user-data honored,"
            " no errors found in logs"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog=sys.argv[0])
    parser.add_argument(
        "--local-images-dir",
        action="store",
        default="/srv/iso",
        help="Local path to where ISOs are downloaded. Default: /srv/iso/",
    )
    parser.add_argument(
        "-i",
        "--image-type",
        action="store",
        default="server",
        choices=["desktop", "server"],
        help="Image type: desktop or server. Default: server",
    )
    parser.add_argument(
        "-s",
        "--series",
        action="store",
        default="mantic",
        choices=list(UbuntuRelease.__members__.keys()),
        help="Image series",
    )
    args = parser.parse_args()
    logging.basicConfig(stream=sys.stdout, level=logging.DEBUG)
    main(args)
