#!/usr/bin/env python
"""SOCKS5 UDP ASSOCIATE probe (PRD FR-3 / AC-4).

Verifies that the upstream SOCKS5 proxy (the Clash mixed-port) supports the
UDP ASSOCIATE data path by sending a DNS query through it and waiting for a
response. Pure stdlib; runs on the host or in any Python container.

Exit code 0 = UDP path works, 1 = it does not.
"""
import argparse
import os
import socket
import struct
import sys


def build_dns_query(name):
    tid = os.urandom(2)
    header = tid + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return header + qname + b"\x00\x01\x00\x01"  # QTYPE=A, QCLASS=IN


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1", help="SOCKS5 proxy host")
    ap.add_argument("--port", type=int, default=7897, help="SOCKS5 proxy port")
    ap.add_argument("--dns-server", default="1.1.1.1", help="UDP target to query")
    ap.add_argument("--name", default="example.com", help="Name to resolve")
    ap.add_argument("--timeout", type=float, default=6.0)
    args = ap.parse_args()

    print(f"probing SOCKS5 UDP ASSOCIATE via {args.host}:{args.port} ...")
    try:
        tcp = socket.create_connection((args.host, args.port), timeout=args.timeout)
    except OSError as exc:
        print(f"FAIL: cannot connect to proxy: {exc}")
        return 1

    tcp.sendall(b"\x05\x01\x00")  # greeting: no-auth
    if tcp.recv(2) != b"\x05\x00":
        print("FAIL: SOCKS5 greeting rejected")
        return 1

    # UDP ASSOCIATE with client address 0.0.0.0:0
    tcp.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0))
    reply = tcp.recv(262)
    if len(reply) < 7 or reply[1] != 0x00:
        rep = reply[1] if len(reply) > 1 else None
        print(f"FAIL: UDP ASSOCIATE rejected (REP={rep})")
        return 1
    atyp = reply[3]
    if atyp == 0x01:
        bnd_host = socket.inet_ntoa(reply[4:8])
        bnd_port = struct.unpack("!H", reply[8:10])[0]
    elif atyp == 0x03:
        ln = reply[4]
        bnd_host = reply[5:5 + ln].decode()
        bnd_port = struct.unpack("!H", reply[5 + ln:7 + ln])[0]
    else:
        print("FAIL: unsupported BND address type in ASSOCIATE reply")
        return 1
    # An unspecified or loopback BND.ADDR is only meaningful on the proxy
    # host itself; a remote client must send datagrams to the proxy address
    # (Clash with allow-lan=false reports 127.0.0.1 here).
    if bnd_host in ("0.0.0.0", "", "127.0.0.1", "::1") and args.host not in ("127.0.0.1", "::1", "localhost"):
        bnd_host = args.host
    print(f"UDP relay endpoint: {bnd_host}:{bnd_port}")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.settimeout(args.timeout)
    dns = build_dns_query(args.name)
    pkt = (b"\x00\x00\x00\x01" + socket.inet_aton(args.dns_server)
           + struct.pack("!H", 53) + dns)
    udp.sendto(pkt, (bnd_host, bnd_port))
    try:
        data, _ = udp.recvfrom(4096)
    except socket.timeout:
        print("FAIL: no UDP response through proxy (UDP ASSOCIATE data path broken)")
        return 1

    if data[:3] != b"\x00\x00\x00" or len(data) < 11:
        print("FAIL: malformed SOCKS5 UDP reply header")
        return 1
    atyp = data[3]
    if atyp == 0x01:
        off = 10
    elif atyp == 0x04:
        off = 22
    else:
        off = 7 + data[4]
    payload = data[off:]
    if payload[:2] != dns[:2]:
        print("FAIL: DNS transaction id mismatch")
        return 1
    ancount = struct.unpack("!H", payload[6:8])[0]
    print(f"OK: DNS answer for {args.name} received through SOCKS5 UDP "
          f"({ancount} answer records)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
