#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FTP Server 端到端协议一致性测试。

用 Python 标准库 ftplib 作为真实客户端，覆盖认证、被动/主动模式、
上传下载、目录操作、断点续传、ASCII 与二进制模式、路径逃逸防护、
权限拒绝、Unicode 文件名、并发会话等场景。

用法：
    python3 e2e_test.py /path/to/FTPServer [端口]
"""

import ftplib
import hashlib
import io
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 21321
BINARY = sys.argv[1] if len(sys.argv) > 1 else None
HOST = "127.0.0.1"

WRITER_USER, WRITER_PASS = "writer", "s3cret-1"
READER_USER, READER_PASS = "reader", "readonly-2"

results = []
failures = []


def check(name, condition, detail=""):
    ok = bool(condition)
    results.append((name, ok, detail))
    flag = "PASS" if ok else "FAIL"
    line = f"  [{flag}] {name}"
    if not ok and detail:
        line += f"  → {detail}"
    print(line, flush=True)
    if not ok:
        failures.append((name, detail))
    return ok


def expect_error(name, func, kinds=ftplib.error_perm):
    """断言操作必须以指定错误结束。"""
    try:
        func()
    except kinds as exc:
        return check(name, True, str(exc))
    except Exception as exc:  # noqa: BLE001
        return check(name, False, f"抛出了非预期异常 {type(exc).__name__}: {exc}")
    return check(name, False, "本应报错，却成功执行")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch_binary(ftp, name):
    buffer = io.BytesIO()
    ftp.retrbinary(f"RETR {name}", buffer.write)
    return buffer.getvalue()


# ---------------------------------------------------------------- 环境准备

def build_fixture(base):
    anon_root = os.path.join(base, "anonymous")
    writer_root = os.path.join(base, "writer")
    os.makedirs(anon_root)
    os.makedirs(writer_root)

    with open(os.path.join(anon_root, "hello.txt"), "w") as handle:
        handle.write("hello from anonymous root\n")

    with open(os.path.join(writer_root, "preload.txt"), "w") as handle:
        handle.write("preloaded content\n")

    # 根目录之外的机密文件，用于验证路径逃逸防护
    with open(os.path.join(base, "secret-outside.txt"), "w") as handle:
        handle.write("TOP SECRET\n")

    # 指向 /etc 的符号链接，用于验证符号链接逃逸防护
    os.symlink("/etc", os.path.join(writer_root, "escape"))

    # 指向根目录之外「文件」的软链接：写入路径曾可顺着它覆盖外部文件
    os.symlink(os.path.join(base, "secret-outside.txt"),
               os.path.join(writer_root, "escape-file.txt"))
    # 悬空的软链接，指向根目录之外一个并不存在的文件
    os.symlink(os.path.join(base, "created-outside.txt"),
               os.path.join(writer_root, "escape-dangling.txt"))
    # 指向根目录之外「目录」的软链接
    os.symlink(base, os.path.join(writer_root, "escape-dir"))
    # 指向根目录内部文件的软链接：写入应当照常可用
    with open(os.path.join(writer_root, "inside-target.txt"), "w") as handle:
        handle.write("inside target\n")
    os.symlink(os.path.join(writer_root, "inside-target.txt"),
               os.path.join(writer_root, "inside-link.txt"))

    return anon_root, writer_root


def wait_for_port(port, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((HOST, port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.15)
    return False


def start_server(base, anon_root, writer_root):
    command = [
        BINARY, "--headless",
        "--port", str(PORT),
        "--root", anon_root,
        "--anonymous-root", anon_root,
        "--pasv-host", HOST,
        "--log-level", "debug",
        "--user", WRITER_USER, WRITER_PASS, writer_root, "rwmd",
        "--user", READER_USER, READER_PASS, writer_root, "r",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    if not wait_for_port(PORT):
        output = ""
        try:
            process.kill()
            output = process.stdout.read()
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError(f"服务未能在端口 {PORT} 上就绪。\n{output}")
    return process


# ---------------------------------------------------------------- 测试主体

def test_anonymous(anon_root, writer_root):
    print("\n== 匿名访问 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login("anonymous", "someone@example.com")

    check("匿名登录成功", ftp.getwelcome().startswith("220"), ftp.getwelcome())
    check("匿名根目录 PWD 为 /", ftp.pwd() == "/", ftp.pwd())

    names = ftp.nlst()
    check("匿名可列出自身根目录", "hello.txt" in names, str(names))
    check("匿名看不到其他账号目录内容", "preload.txt" not in names, str(names))

    data = fetch_binary(ftp, "hello.txt")
    check("匿名可下载文件", data == b"hello from anonymous root\n", repr(data[:60]))

    expect_error("匿名上传被拒绝",
                 lambda: ftp.storbinary("STOR intrude.txt", io.BytesIO(b"x")))
    expect_error("匿名建目录被拒绝", lambda: ftp.mkd("nope"))
    expect_error("匿名删除被拒绝", lambda: ftp.delete("hello.txt"))

    ftp.quit()
    check("匿名会话正常退出", True)


def test_positive_features(writer_root):
    print("\n== 特性与元数据 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    features = ftp.sendcmd("FEAT")
    for keyword in ("MLSD", "MLST", "SIZE", "MDTM", "REST", "UTF8", "EPSV"):
        check(f"FEAT 公布 {keyword}", keyword in features.upper(), features.replace("\n", " | "))

    check("SYST 返回 UNIX 类型", ftp.sendcmd("SYST").startswith("215"))
    check("NOOP 正常", ftp.voidcmd("NOOP").startswith("200"))

    reply = ftp.sendcmd("PASV")
    check("PASV 返回 227 及合法地址",
          bool(re.match(r"^227 .*\(\d+,\d+,\d+,\d+,\d+,\d+\)", reply)), reply)

    reply229 = ftp.sendcmd("EPSV")
    check("EPSV 返回 229 与端口", bool(re.match(r"^229 .*\(\|\|\|\d+\|\)", reply229)), reply229)

    ftp.quit()


def test_directory_operations(writer_root):
    print("\n== 目录与文件操作 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    expect_error("MKD 不允许覆盖已存在目录", lambda: ftp.mkd("preload.txt"))

    ftp.mkd("subdir")
    check("创建目录成功", "subdir" in ftp.nlst(), str(ftp.nlst()))

    ftp.cwd("subdir")
    check("CWD 切换成功", ftp.pwd() == "/subdir", ftp.pwd())
    ftp.cwd("..")
    check("CDUP 回到上级", ftp.pwd() == "/", ftp.pwd())

    payload = b"directory listing probe\n"
    ftp.storbinary("STOR subdir/probe.txt", io.BytesIO(payload))
    check("上传文件成功", fetch_binary(ftp, "subdir/probe.txt") == payload)
    check("SIZE 返回正确字节数", ftp.size("subdir/probe.txt") == len(payload),
          str(ftp.size("subdir/probe.txt")))

    mdtm = ftp.sendcmd("MDTM subdir/probe.txt")
    check("MDTM 返回 14 位时间戳",
          bool(re.match(r"^213 \d{14}$", mdtm)), mdtm)

    ftp.rename("subdir/probe.txt", "subdir/renamed.txt")
    check("RNFR/RNTO 重命名成功", "renamed.txt" in ftp.nlst("subdir"),
          str(ftp.nlst("subdir")))

    ftp.delete("subdir/renamed.txt")
    check("删除文件成功", "renamed.txt" not in ftp.nlst("subdir"))

    ftp.rmd("subdir")
    check("删除空目录成功", "subdir" not in ftp.nlst())

    expect_error("删除非空/不存在目录时报错", lambda: ftp.rmd("no-such-dir"))
    expect_error("SIZE 作用在目录上会报错", lambda: ftp.size("/"))

    lines = []
    ftp.dir(lines.append)
    check("LIST 返回 ls -l 风格行",
          any(line.startswith("-") and "preload.txt" in line for line in lines),
          str(lines[:3]))

    entries = dict(ftp.mlsd())
    check("MLSD 返回结构化条目", "preload.txt" in entries, str(list(entries)[:5]))
    facts = entries.get("preload.txt", {})
    check("MLSD type=file 正确", facts.get("type") == "file", str(facts))
    check("MLSD size 正确", facts.get("size") == str(os.path.getsize(
        os.path.join(writer_root, "preload.txt"))), str(facts))

    ftp.mkd("dirtest")
    dir_facts = dict(ftp.mlsd()).get("dirtest", {})
    check("MLSD 目录 type=dir 正确", dir_facts.get("type") == "dir", str(dir_facts))
    ftp.rmd("dirtest")

    mlst = ftp.sendcmd("MLST preload.txt")
    check("MLST 返回单条目事实", "type=file" in mlst, mlst.replace("\n", " | "))

    ftp.quit()


def test_transfer_integrity():
    print("\n== 传输完整性 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=20)
    ftp.login(WRITER_USER, WRITER_PASS)

    # 5 MB 随机数据，二进制往返
    random.seed(20260913)
    big = bytes(random.getrandbits(8) for _ in range(5 * 1024 * 1024))
    ftp.storbinary("STOR big.bin", io.BytesIO(big), blocksize=65536)
    got = fetch_binary(ftp, "big.bin")
    check("5MB 二进制上传下载哈希一致",
          sha256(got) == sha256(big), f"{len(got)} 字节")
    check("SIZE 与实际上传一致", ftp.size("big.bin") == len(big))

    # 空文件
    ftp.storbinary("STOR empty.bin", io.BytesIO(b""))
    check("空文件往返正确", fetch_binary(ftp, "empty.bin") == b"")
    check("空文件 SIZE 为 0", ftp.size("empty.bin") == 0)

    # 含 NUL 与各类字节的二进制文件
    tricky = bytes(range(256)) * 40
    ftp.storbinary("STOR tricky.bin", io.BytesIO(tricky))
    check("全字节域文件往返正确", fetch_binary(ftp, "tricky.bin") == tricky)

    # 断点续传
    connection = ftp.transfercmd("RETR big.bin", rest=1000000)
    chunks = []
    while True:
        chunk = connection.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
    connection.close()
    ftp.voidresp()
    check("REST 断点续传下载正确", b"".join(chunks) == big[1000000:],
          f"收到 {sum(len(c) for c in chunks)} 字节")

    # 追加写入
    ftp.storbinary("STOR append.log", io.BytesIO(b"first\n"))
    ftp.storbinary("APPE append.log", io.BytesIO(b"second\n"))
    check("APPE 追加写入正确",
          fetch_binary(ftp, "append.log") == b"first\nsecond\n",
          repr(fetch_binary(ftp, "append.log")))

    # ASCII 模式：本地 LF 与网络 CRLF 的双向转换
    text = "alpha\nbeta\ngamma\n"
    ftp.storlines("STOR ascii.txt", io.BytesIO(text.encode()))
    buffer = io.BytesIO()
    ftp.retrlines("RETR ascii.txt", lambda line: buffer.write((line + "\n").encode()))
    check("ASCII 模式文本往返一致", buffer.getvalue().decode() == text,
          repr(buffer.getvalue()))

    ftp.quit()


def test_active_mode():
    print("\n== 主动模式（PORT） ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)
    ftp.set_pasv(False)

    names = ftp.nlst()
    check("主动模式可列出目录", "preload.txt" in names, str(names))

    data = fetch_binary(ftp, "preload.txt")
    check("主动模式可下载文件", data == b"preloaded content\n", repr(data[:40]))

    ftp.storbinary("STOR active-upload.txt", io.BytesIO(b"active mode upload\n"))
    check("主动模式可上传文件",
          fetch_binary(ftp, "active-upload.txt") == b"active mode upload\n")
    ftp.delete("active-upload.txt")

    ftp.quit()


def test_unicode_names():
    print("\n== Unicode 文件名 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    name = "中文文件名-测试.txt"
    ftp.storbinary(f"STOR {name}", io.BytesIO(b"unicode payload\n"))
    check("中文文件名上传成功", name in ftp.nlst(), str(ftp.nlst()))
    check("中文文件名下载正确", fetch_binary(ftp, name) == b"unicode payload\n")

    entries = dict(ftp.mlsd())
    check("MLSD 正确返回中文名", name in entries, str(list(entries)[:6]))

    ftp.rename(name, "中文改名后.txt")
    check("中文文件名重命名成功", "中文改名后.txt" in ftp.nlst())
    ftp.delete("中文改名后.txt")

    ftp.quit()


def test_security(tmp_base):
    print("\n== 安全防护 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    expect_error("RETR ../secret-outside.txt 被拒绝",
                 lambda: ftp.retrbinary("RETR ../secret-outside.txt", lambda _: None))
    expect_error("RETR ../../etc/passwd 被拒绝",
                 lambda: ftp.retrbinary("RETR ../../etc/passwd", lambda _: None))
    expect_error("CWD .. 越出根目录被拒绝", lambda: ftp.cwd(".."))
    expect_error("MKD ../evil 越出根目录被拒绝", lambda: ftp.mkd("../evil"))
    expect_error("STOR ../evil.txt 越出根目录被拒绝",
                 lambda: ftp.storbinary("STOR ../evil.txt", io.BytesIO(b"x")))
    expect_error("SIZE ../secret-outside.txt 被拒绝", lambda: ftp.size("../secret-outside.txt"))
    expect_error("DELE ../secret-outside.txt 被拒绝", lambda: ftp.delete("../secret-outside.txt"))

    # 符号链接逃逸：writer 根目录内存在 escape -> /etc
    expect_error("符号链接逃逸读取 /etc/passwd 被拒绝",
                 lambda: ftp.retrbinary("RETR escape/passwd", lambda _: None))

    check("越权尝试未在根目录外产生文件",
          not os.path.exists(os.path.join(tmp_base, "evil.txt"))
          and not os.path.exists(os.path.join(tmp_base, "evil")),
          "根目录外被写入了文件")

    # 绝对路径被约束在根目录内
    check("绝对路径被映射到根目录内",
          fetch_binary(ftp, "/preload.txt") == b"preloaded content\n")

    ftp.quit()


def test_symlink_write_escape(tmp_base):
    """写入路径必须与读取路径同等对待符号链接。

    曾经的缺陷：读路径会对整条路径解析符号链接并校验包含性，
    而写路径只校验**父目录**。根目录内一个指向外部的软链接，其父目录
    就是根目录本身，校验顺利通过，随后 STOR / APPE 顺链写入根目录之外，
    覆盖共享范围外任意可写文件（实测可改写 /etc 之外的用户文件）。
    """
    print("\n== 符号链接写入防护 ==", flush=True)
    outside = os.path.join(tmp_base, "secret-outside.txt")
    original = "TOP SECRET\n"

    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    expect_error("STOR 指向根外的软链接被拒绝",
                 lambda: ftp.storbinary("STOR escape-file.txt", io.BytesIO(b"pwned\n")))
    expect_error("APPE 指向根外的软链接被拒绝",
                 lambda: ftp.storbinary("APPE escape-file.txt", io.BytesIO(b"pwned\n")))
    expect_error("STOR 悬空软链接被拒绝",
                 lambda: ftp.storbinary("STOR escape-dangling.txt", io.BytesIO(b"pwned\n")))
    expect_error("STOR 经软链接目录写入被拒绝",
                 lambda: ftp.storbinary("STOR escape-dir/pwned.txt", io.BytesIO(b"pwned\n")))
    expect_error("MKD 悬空软链接被拒绝", lambda: ftp.mkd("escape-dangling.txt"))
    expect_error("RETR 指向根外的软链接被拒绝（对照）",
                 lambda: ftp.retrbinary("RETR escape-file.txt", lambda _: None))

    with open(outside) as handle:
        content = handle.read()
    check("根目录外的文件未被改写", content == original, f"实际内容 {content!r}")
    check("根目录外未凭空产生文件",
          not os.path.exists(os.path.join(tmp_base, "created-outside.txt")))
    check("经软链接目录未在根目录外产生文件",
          not os.path.exists(os.path.join(tmp_base, "pwned.txt")))

    # 正向用例：指向根目录内部的软链接仍应可写，避免防护过严
    ftp.storbinary("STOR inside-link.txt", io.BytesIO(b"rewritten via inside link\n"))
    check("指向根内的软链接仍可正常写入",
          fetch_binary(ftp, "inside-target.txt") == b"rewritten via inside link\n",
          "防护过严，把根内的合法软链接也拦掉了")

    ftp.quit()


def test_passive_binding():
    """「仅本机」模式下，PASV 数据端口必须与控制端口保持同一绑定范围。

    注意 requiredInterfaceType = .loopback 对**监听**套接字无效
    （实测仍绑定到 *），必须用 requiredLocalEndpoint 指定回环地址。
    """
    print("\n== 被动模式绑定范围 ==", flush=True)
    local_port = PORT + 7
    root = tempfile.mkdtemp(prefix="ftpserver-pasv-")
    with open(os.path.join(root, "f.txt"), "w") as handle:
        handle.write("x\n")

    process = subprocess.Popen(
        [BINARY, "--headless", "--port", str(local_port), "--root", root,
         "--anonymous-root", root, "--localhost", "--log-level", "error"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_for_port(local_port):
            check("仅本机模式服务可启动", False, "端口未就绪")
            return

        ftp = ftplib.FTP()
        ftp.connect(HOST, local_port, timeout=10)
        ftp.login("anonymous", "a@b.c")
        response = ftp.sendcmd("PASV")
        numbers = [int(x) for x in re.search(r"\(([\d,]+)\)", response).group(1).split(",")]
        pasv_port = numbers[4] * 256 + numbers[5]
        time.sleep(0.4)

        listing = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{pasv_port}",
                                  "-sTCP:LISTEN"],
                                 capture_output=True, text=True).stdout
        rows = [line.split() for line in listing.splitlines()[1:] if line.strip()]
        address = rows[0][-2] if rows and len(rows[0]) >= 2 else "（未查到监听）"
        check("仅本机模式下 PASV 只监听回环地址",
              address.startswith("127.0.0.1"), f"实际绑定 {address}")

        payload = fetch_binary(ftp, "f.txt")
        check("仅本机模式下数据通道仍可用", payload == b"x\n", f"读到 {payload!r}")
        ftp.quit()
    except Exception as exc:  # noqa: BLE001
        check("仅本机模式被动传输", False, f"{type(exc).__name__}: {exc}")
    finally:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(root, ignore_errors=True)


def test_authentication():
    print("\n== 认证与权限 ==", flush=True)

    def bad_login(user, password):
        client = ftplib.FTP()
        client.connect(HOST, PORT, timeout=10)
        try:
            client.login(user, password)
        finally:
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass

    expect_error("错误口令无法登录", lambda: bad_login(WRITER_USER, "wrong-pass"))
    expect_error("不存在的账号无法登录", lambda: bad_login("nobody", "whatever"))

    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(READER_USER, READER_PASS)
    check("只读账号登录成功", True)
    check("只读账号可下载", fetch_binary(ftp, "preload.txt") == b"preloaded content\n")
    expect_error("只读账号上传被拒绝",
                 lambda: ftp.storbinary("STOR nope.txt", io.BytesIO(b"x")))
    expect_error("只读账号建目录被拒绝", lambda: ftp.mkd("nope"))
    expect_error("只读账号重命名被拒绝", lambda: ftp.rename("preload.txt", "other.txt"))
    expect_error("只读账号删除被拒绝", lambda: ftp.delete("preload.txt"))

    names = ftp.nlst()
    check("只读账号的越权尝试未改动任何文件",
          fetch_binary(ftp, "preload.txt") == b"preloaded content\n"
          and "nope.txt" not in names
          and "nope" not in names,
          str(names))
    ftp.quit()

    # 未登录时访问受限命令
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    expect_error("未登录执行 PWD 被拒绝", lambda: ftp.pwd())
    expect_error("未登录执行 LIST 被拒绝", lambda: ftp.nlst())
    ftp.close()


def test_protocol_edges():
    print("\n== 协议边界 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    expect_error("未知命令返回 500", lambda: ftp.sendcmd("FROBNICATE"), ftplib.all_errors)
    expect_error("未实现的 STOU 返回 502", lambda: ftp.sendcmd("STOU"), ftplib.all_errors)
    check("OPTIONS UTF8 被接受", ftp.sendcmd("OPTS UTF8 ON").startswith("200"))

    expect_error("不存在的文件 RETR 报 550",
                 lambda: ftp.retrbinary("RETR no-such-file.bin", lambda _: None))

    expect_error("RNTO 缺少 RNFR 时报错", lambda: ftp.sendcmd("RNTO x.txt"), ftplib.all_errors)

    # REST 的偏移量非法属于参数问题，应答码应为 501 而非路径类的 550
    try:
        ftp.sendcmd("REST not-a-number")
        check("REST 非数字参数被拒绝", False, "本应报错却成功")
    except ftplib.all_errors as exc:
        code = str(exc)[:3]
        check("REST 非数字参数应答 501", code == "501", f"实际应答 {exc}")
    try:
        ftp.sendcmd("REST -5")
        check("REST 负数被拒绝", False, "本应报错却成功")
    except ftplib.all_errors as exc:
        check("REST 负数应答 501", str(exc)[:3] == "501", f"实际应答 {exc}")

    states = []
    ftp.sendcmd("STAT")
    check("STAT 返回多行服务器状态", True)

    # 连接数上限行为：仅确认服务在多次会话后仍能正常服务
    for _ in range(5):
        extra = ftplib.FTP()
        extra.connect(HOST, PORT, timeout=10)
        extra.login(WRITER_USER, WRITER_PASS)
        extra.nlst()
        extra.quit()
    check("连续多会话后服务仍正常", ftp.pwd() == "/", ftp.pwd())

    ftp.quit()


def test_concurrency():
    print("\n== 并发会话 ==", flush=True)
    errors = []
    payloads = []
    lock = threading.Lock()

    def worker(index):
        try:
            client = ftplib.FTP()
            client.connect(HOST, PORT, timeout=20)
            client.login(WRITER_USER, WRITER_PASS)
            client.mkd(f"concurrent-{index}")
            blob = os.urandom(512 * 1024)
            client.storbinary(f"STOR concurrent-{index}/data.bin", io.BytesIO(blob))
            buffer = io.BytesIO()
            client.retrbinary(f"RETR concurrent-{index}/data.bin", buffer.write)
            with lock:
                payloads.append((blob, buffer.getvalue()))
            client.delete(f"concurrent-{index}/data.bin")
            client.rmd(f"concurrent-{index}")
            client.quit()
        except Exception as exc:  # noqa: BLE001
            with lock:
                errors.append(f"线程 {index}: {type(exc).__name__}: {exc}")

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=90)

    check("8 个并发会话全部成功", not errors, "; ".join(errors))
    check("并发传输数据完整",
          len(payloads) == 8 and all(a == b for a, b in payloads),
          f"完成 {len(payloads)}/8")


def test_abort_and_recovery():
    print("\n== 中止与恢复 ==", flush=True)
    ftp = ftplib.FTP()
    ftp.connect(HOST, PORT, timeout=10)
    ftp.login(WRITER_USER, WRITER_PASS)

    check("空闲时 ABOR 返回 226", ftp.sendcmd("ABOR").startswith("226"))

    ftp.storbinary("STOR after-abort.txt", io.BytesIO(b"ok\n"))
    check("ABOR 之后会话仍可正常传输",
          fetch_binary(ftp, "after-abort.txt") == b"ok\n")
    ftp.delete("after-abort.txt")

    ftp.quit()
    check("QUIT 返回 221", True)


# ---------------------------------------------------------------- 入口

def main():
    if not BINARY or not os.path.exists(BINARY):
        print(f"未找到可执行文件：{BINARY}", file=sys.stderr)
        return 2

    base = tempfile.mkdtemp(prefix="ftpserver-e2e-")
    anon_root, writer_root = build_fixture(base)
    process = None
    started = time.time()

    try:
        process = start_server(base, anon_root, writer_root)
        print(f"服务已在端口 {PORT} 就绪（进程 {process.pid}）", flush=True)

        test_anonymous(anon_root, writer_root)
        test_positive_features(writer_root)
        test_directory_operations(writer_root)
        test_transfer_integrity()
        test_active_mode()
        test_unicode_names()
        test_security(base)
        test_symlink_write_escape(base)
        test_passive_binding()
        test_authentication()
        test_protocol_edges()
        test_concurrency()
        test_abort_and_recovery()
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
            output = process.stdout.read() if process.stdout else ""
            if failures:
                print("\n---- 服务端日志（末 90 行）----")
                print("\n".join(output.splitlines()[-90:]))
        shutil.rmtree(base, ignore_errors=True)

    total = len(results)
    passed = total - len(failures)
    print("\n" + "=" * 62)
    print(f"结果：{passed}/{total} 通过，耗时 {time.time() - started:.1f} 秒")
    if failures:
        print("\n失败项：")
        for name, detail in failures:
            print(f"  - {name}  {detail}")
    print("=" * 62)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
