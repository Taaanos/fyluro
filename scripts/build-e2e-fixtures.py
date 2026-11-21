#!/usr/bin/env python3
"""Build and check the gitignored E2E source-card fixtures.

By default (or with `--synthetic`), generates tiny deterministic synthetic
`SD_CARD1` and `SD_CARD2` trees with valid containers and embedded metadata,
and verifies them against `Tests/TestingDirs/fixture-manifest.json`.

With `--real`, maps files from a local real-media directory given by
`FYLURO_FIXTURE_SOURCE_DIR` and tracks them separately in
`Tests/TestingDirs/fixture-manifest.real.json` (gitignored) so the committed
synthetic manifest is never overwritten.

The card paths below are referenced by name in the E2E harnesses
(FAST_SOURCE_SUBSET_PATHS in scripts/existing-hdd-e2e.py, the
E2E_EXISTING_HDD_* fixture.json files, matrixSlimRelativePaths in
Tests/fyluroLauncherTests/LauncherAppE2ETests.swift, and
scripts/e2e-verify-failure-test.sh) -- keep them in sync.
"""

import argparse
import datetime
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path
from typing import Any, Callable, Dict, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTING_DIRS = REPO_ROOT / "Tests" / "TestingDirs"
SYNTHETIC_MANIFEST_PATH = TESTING_DIRS / "fixture-manifest.json"
REAL_MANIFEST_PATH = TESTING_DIRS / "fixture-manifest.real.json"

PHOTO_EXTENSIONS = {"jpg", "jpeg", "png", "heic", "heif", "dng", "cr2", "cr3", "arw", "gpr"}
VIDEO_EXTENSIONS = {"mov", "mp4", "m4v", "insv"}
AUDIO_EXTENSIONS = {"wav", "mp3", "m4a", "aac", "caf", "aif", "aiff"}

# Minimal valid 1x1 baseline grayscale JPEG body (SOF0 + DHT + SOS + EOI).
TINY_JPEG_BODY = bytes.fromhex(
    "ffdb004300"
    "0302020302020303030304030304050805050404050a070706080c0a0c0c0b0a0b0b"
    "0d0e12100d0e110e0b0b1016101113141515150c0f171816141812141514"
    "ffc0000b080001000101011100"
    "ffc40014000100000000000000000000000000000009"
    "ffc40014100100000000000000000000000000000000"
    "ffda0008010100003f00d2cf20ffd9"
)

# Minimal valid 64x64 Main-profile H.265 VPS, SPS, PPS, and 1-CTU IDR slice.
HEVC_VPS = bytes.fromhex("40010c01ffff01600000030090000003000003003c959809")
HEVC_SPS = bytes.fromhex("42010101600000030090000003000003003ca00808040596566924caaf010000030001000003001e08")
HEVC_PPS = bytes.fromhex("4401c172b46240")
HEVC_IDR = bytes.fromhex(
    "2601af1d00000300000300000300000300000300000300000300000300000300000300"
    "0003000003000003000003000003000003000003000003000003000003000003000003"
    "0000030000030000030000030000030000030000030000030000030000030000030000"
    "030000030000030000030000"
)

# Seconds between 1904-01-01 (MP4/QuickTime epoch) and 1970-01-01 (Unix epoch).
MP4_EPOCH_OFFSET = 2082844800

CARD_MAPPINGS = {
    "SD_CARD1": {
        "iphone 12 mini/IMG_2940.HEIC": "DCIM/IMG_2940.HEIC",
        # pinned: matrix slim subset + duplicate source + verify-failure fixture
        "iphone 13 pro/IMG_8236.HEIC": "DCIM/IMG_8236.HEIC",
        "iphone 13 pro/IMG_8248.DNG": "DCIM/IMG_8248.DNG",
        "iphone 13 pro/IMG_8249.MOV": "DCIM/IMG_8249.MOV",
        "iphone 15 pro/IMG_0083.DNG": "DCIM/IMG_0083.DNG",
        "iphone 15 pro/IMG_0168.MOV": "DCIM/IMG_0168.MOV",
        # pinned: matrix slim subset + conflict source
        "iphone 15 pro/IMG_0187.HEIC": "DCIM/IMG_0187.HEIC",
        "iphone 16/IMG_0245.MOV": "DCIM/IMG_0245.MOV",
        # screenshot: no Make/Model -> unknown-camera label coverage
        "screenshots/IMG_0076.PNG": "DCIM/IMG_0076.PNG",
        # Blackmagic-app iPhone clip: nonstandard naming coverage
        "iphone 15 pro/A001_06041206_C097.mov": "DCIM/A001_06041206_C097.mov",
        # standalone audio recording, no paired video: standalone-Audio-candidate coverage
        "iphone recordings/iphone recording.m4a": "DCIM/iphone recording.m4a",
    },
    "SD_CARD2": {
        # pinned: duplicate source
        "rx100/DSC01930.JPG": "DCIM/100MSDCF/DSC01930.JPG",
        "rx100/DSC02701.ARW": "DCIM/100MSDCF/DSC02701.ARW",
        # same-basename RAW+JPG pair
        "rx100 mk6/DSC00421.JPG": "DCIM/100MSDCF/DSC00421.JPG",
        "rx100 mk6/DSC00421.ARW": "DCIM/100MSDCF/DSC00421.ARW",
        "a7c2/DSC02577.ARW": "DCIM/100MSDCF/DSC02577.ARW",
        "a6000/DSC08259.ARW": "DCIM/100MSDCF/DSC08259.ARW",
        "a380/DSC09387.ARW": "DCIM/100MSDCF/DSC09387.ARW",
        "5DM2/IMG_1765.CR2": "DCIM/100CANON/IMG_1765.CR2",
        # GoPro (GPR is a supported RAW photo format, bucketed like other RAW formats)
        "hero 10/G0010306.JPG": "DCIM/100GOPRO/G0010306.JPG",
        "hero 10/G0010306.GPR": "DCIM/100GOPRO/G0010306.GPR",
        "hero 10/G0010044.JPG": "DCIM/100GOPRO/G0010044.JPG",
        "hero 10/G0010044.GPR": "DCIM/100GOPRO/G0010044.GPR",
        "hero 10/GX010645.MP4": "DCIM/100GOPRO/GX010645.MP4",
        "hero 10/GX020024.MP4": "DCIM/100GOPRO/GX020024.MP4",
        "action-4/DJI_20240218122338_0019_D.JPG": "DCIM/100MEDIA/DJI_20240218122338_0019_D.JPG",
        "action-4/DJI_20240218140744_0024_D.DNG": "DCIM/100MEDIA/DJI_20240218140744_0024_D.DNG",
        "action-4/DJI_20240204134712_0013_D.MP4": "DCIM/100MEDIA/DJI_20240204134712_0013_D.MP4",
        "action-6/DJI_20260613062714_0010_D.MP4": "DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4",
        # DJI drone/pocket (SRT sidecar pair; WAV is video-companion-audio sidecar coverage)
        "mini-4-pro/DJI_20260523115129_0558_D.DNG": "DCIM/DJI_001/DJI_20260523115129_0558_D.DNG",
        "mini-4-pro/DJI_20260523115257_0565_D.MP4": "DCIM/DJI_001/DJI_20260523115257_0565_D.MP4",
        "mini-4-pro/DJI_20260523115257_0565_D.SRT": "DCIM/DJI_001/DJI_20260523115257_0565_D.SRT",
        "pocket-3/DJI_20240126194607_0117_D.JPG": "DCIM/DJI_001/DJI_20240126194607_0117_D.JPG",
        "pocket-3/DJI_20240126194607_0117_D.DNG": "DCIM/DJI_001/DJI_20240126194607_0117_D.DNG",
        "pocket-3/DJI_20240126093104_0012_D.MP4": "DCIM/DJI_001/DJI_20240126093104_0012_D.MP4",
        "pocket-3/DJI_20240126093104_0012_D.WAV": "DCIM/DJI_001/DJI_20240126093104_0012_D.WAV",
        "samsung galaxy a54 /20240809_160800.jpg": "DCIM/CAMERA/20240809_160800.jpg",
        "samsung galaxy a54 /20240809_164400.mp4": "DCIM/CAMERA/20240809_164400.mp4",
        # Lightroom export (re-exported metadata coverage)
        "Lightroom exports/DJI_20240908175300_0011_D.JPG": "DCIM/EXPORT/DJI_20240908175300_0011_D.JPG",
        "insta360/VID_20231023_055225_00_645.insv": "DCIM/Camera01/VID_20231023_055225_00_645.insv",
        # Sony video clips + real NonRealTimeMeta XML sidecar
        # pinned: conflict source
        "a7c2/20250824_C2864.MP4": "PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4",
        "a7c2/20260618_C5262.MP4": "PRIVATE/M4ROOT/CLIP/20260618_C5262.MP4",
        "a7c2/20260618_C5262M01.XML": "PRIVATE/M4ROOT/CLIP/20260618_C5262M01.XML",
    },
}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_iso_utc(iso_str: str) -> datetime.datetime:
    dt = datetime.datetime.fromisoformat(iso_str)
    if dt.tzinfo is None:
        return dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)


def exif_datetime_from_iso(iso_str: str) -> str:
    dt = datetime.datetime.fromisoformat(iso_str)
    return dt.strftime("%Y:%m:%d %H:%M:%S")


def mp4_seconds_from_iso(iso_str: str) -> int:
    return int(parse_iso_utc(iso_str).timestamp()) + MP4_EPOCH_OFFSET


def iso_box(typ: bytes, payload: bytes) -> bytes:
    return struct.pack(">I4s", 8 + len(payload), typ) + payload


def iso_fullbox(typ: bytes, version: int, flags: int, payload: bytes) -> bytes:
    return iso_box(typ, struct.pack(">I", (version << 24) | flags) + payload)


def build_tiff_exif(
    *,
    make: str = "",
    model: str = "",
    dto: str = "",
    unique_camera_model: str = "",
    xmp_packet: Optional[bytes] = None,
    include_image_ifd: bool = False,
    cr2_header: bool = False,
) -> bytes:
    """Build a deterministic little-endian TIFF/EXIF (or CR2) structure."""
    entries = []
    if include_image_ifd:
        entries.extend([
            (0x0100, 4, 1, 1),   # ImageWidth
            (0x0101, 4, 1, 1),   # ImageLength
            (0x0102, 3, 1, 8),   # BitsPerSample
            (0x0103, 3, 1, 1),   # Compression = None
            (0x0106, 3, 1, 1),   # PhotometricInterpretation = BlackIsZero
        ])
    if make:
        entries.append((0x010F, 2, None, make.encode("utf-8") + b"\x00"))
    if model:
        entries.append((0x0110, 2, None, model.encode("utf-8") + b"\x00"))
    if include_image_ifd:
        entries.extend([
            (0x0111, 4, 1, "PIXEL"),  # StripOffsets placeholder
            (0x0115, 3, 1, 1),        # SamplesPerPixel
            (0x0117, 4, 1, 1),        # StripByteCounts
        ])
    if xmp_packet:
        entries.append((0x02BC, 1, None, xmp_packet))
    if dto:
        entries.append((0x8769, 4, 1, "EXIF_IFD"))
    if unique_camera_model:
        entries.append((0xC614, 2, None, unique_camera_model.encode("utf-8") + b"\x00"))

    entries.sort(key=lambda item: item[0])

    ifd0_offset = 16 if cr2_header else 8
    cursor = ifd0_offset + 2 + len(entries) * 12 + 4

    pixel_offset = cursor
    if include_image_ifd:
        cursor += 2

    data_offsets: Dict[int, int] = {}
    for tag, typ, count, val in entries:
        if isinstance(val, bytes) and len(val) > 4:
            data_offsets[tag] = cursor
            cursor += len(val)
            if len(val) % 2 == 1:
                cursor += 1

    exif_ifd_offset = cursor
    dto_bytes = dto.encode("utf-8") + b"\x00" if dto else b""
    dto_offset = 0
    if dto:
        cursor += 2 + 12 + 4
        if len(dto_bytes) > 4:
            dto_offset = cursor
            cursor += len(dto_bytes)

    out = bytearray(b"II*\x00" + struct.pack("<I", ifd0_offset))
    if cr2_header:
        out += b"CR\x02\x00" + struct.pack("<I", ifd0_offset)

    out += struct.pack("<H", len(entries))
    for tag, typ, count, val in entries:
        if val == "PIXEL":
            out += struct.pack("<HHII", tag, typ, 1, pixel_offset)
        elif val == "EXIF_IFD":
            out += struct.pack("<HHII", tag, typ, 1, exif_ifd_offset)
        elif isinstance(val, bytes):
            cnt = len(val)
            if cnt <= 4:
                out += struct.pack("<HHI", tag, typ, cnt) + val + b"\x00" * (4 - cnt)
            else:
                out += struct.pack("<HHII", tag, typ, cnt, data_offsets[tag])
        else:
            out += struct.pack("<HHII", tag, typ, count, val)
    out += struct.pack("<I", 0)

    if include_image_ifd:
        out += b"\x80\x00"

    for tag, typ, count, val in entries:
        if isinstance(val, bytes) and len(val) > 4:
            out += val
            if len(val) % 2 == 1:
                out += b"\x00"

    if dto:
        out += struct.pack("<H", 1)
        if len(dto_bytes) <= 4:
            out += struct.pack("<HHI", 0x9003, 2, len(dto_bytes)) + dto_bytes + b"\x00" * (4 - len(dto_bytes))
        else:
            out += struct.pack("<HHII", 0x9003, 2, len(dto_bytes), dto_offset)
        out += struct.pack("<I", 0)
        if len(dto_bytes) > 4:
            out += dto_bytes

    return bytes(out)


def build_xmp_packet(*, product_name: str = "") -> bytes:
    body = (
        '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description rdf:about="" xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/">'
        f"<drone-dji:ProductName>{product_name}</drone-dji:ProductName>"
        "</rdf:Description></rdf:RDF></x:xmpmeta>"
        '<?xpacket end="w"?>'
    )
    return body.encode("utf-8")


def build_jpeg(spec: Dict[str, Any]) -> bytes:
    xmp = build_xmp_packet(product_name=spec["product_name"]) if spec.get("product_name") else None
    exif_tiff = build_tiff_exif(
        make=spec.get("make", ""),
        model=spec.get("model", ""),
        dto=exif_datetime_from_iso(spec["capture_dt"]),
        unique_camera_model=spec.get("unique_camera_model", ""),
    )
    exif_payload = b"Exif\x00\x00" + exif_tiff
    segments = b"\xff\xe1" + struct.pack(">H", 2 + len(exif_payload)) + exif_payload
    if xmp:
        xmp_payload = b"http://ns.adobe.com/xap/1.0/\x00" + xmp
        segments += b"\xff\xe1" + struct.pack(">H", 2 + len(xmp_payload)) + xmp_payload
    return b"\xff\xd8" + segments + TINY_JPEG_BODY


def build_png(spec: Dict[str, Any]) -> bytes:
    def chunk(typ: bytes, data: bytes) -> bytes:
        return struct.pack(">I4s", len(data), typ) + data + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    idat = zlib.compress(b"\x00\xff\xff\xff")
    exif = build_tiff_exif(
        make=spec.get("make", ""),
        model=spec.get("model", ""),
        dto=exif_datetime_from_iso(spec["capture_dt"]),
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"eXIf", exif)
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )


def build_heic(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"heic\x00\x00\x00\x00mif1heic")
    hdlr = iso_fullbox(b"hdlr", 0, 0, b"\x00\x00\x00\x00pict" + b"\x00" * 12 + b"\x00")
    dref = iso_fullbox(b"dref", 0, 0, struct.pack(">I", 1) + iso_fullbox(b"url ", 0, 1, b""))
    dinf = iso_box(b"dinf", dref)
    pitm = iso_fullbox(b"pitm", 0, 0, struct.pack(">H", 1))
    infe1 = iso_fullbox(b"infe", 2, 0, struct.pack(">HH", 1, 0) + b"hvc1\x00")
    infe2 = iso_fullbox(b"infe", 2, 0, struct.pack(">HH", 2, 0) + b"Exif\x00")
    iinf = iso_fullbox(b"iinf", 0, 0, struct.pack(">H", 2) + infe1 + infe2)
    iref = iso_fullbox(b"iref", 0, 0, iso_box(b"cdsc", struct.pack(">HHH", 2, 1, 1)))
    ispe = iso_fullbox(b"ispe", 0, 0, struct.pack(">II", 64, 64))
    pixi = iso_fullbox(b"pixi", 0, 0, bytes([3, 8, 8, 8]))

    hvcc_body = bytearray([
        1, 0x01, 0x60, 0, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 60, 0xF0, 0,
        0xFC, 0xFC, 0xF8, 0xF8, 0, 0, 0x0F, 3,
    ])
    for nal_type, nal_bytes in ((0x20, HEVC_VPS), (0x21, HEVC_SPS), (0x22, HEVC_PPS)):
        hvcc_body += struct.pack(">BHH", nal_type, 1, len(nal_bytes)) + nal_bytes
    hvcc = iso_box(b"hvcC", bytes(hvcc_body))

    ipco = iso_box(b"ipco", ispe + pixi + hvcc)
    ipma = iso_fullbox(b"ipma", 0, 0, struct.pack(">IHBBBB", 1, 1, 3, 0x81, 0x82, 0x83))
    iprp = iso_box(b"iprp", ipco + ipma)

    tiff_exif = build_tiff_exif(
        make=spec.get("make", ""),
        model=spec.get("model", ""),
        dto=exif_datetime_from_iso(spec["capture_dt"]),
    )
    exif_item = struct.pack(">I", 6) + b"Exif\x00\x00" + tiff_exif
    img_item = struct.pack(">I", len(HEVC_IDR)) + HEVC_IDR

    def build_meta(offset1: int, offset2: int) -> bytes:
        iloc_payload = struct.pack(">BBH", 0x44, 0x00, 2)
        iloc_payload += struct.pack(">HHHII", 1, 0, 1, offset1, len(img_item))
        iloc_payload += struct.pack(">HHHII", 2, 0, 1, offset2, len(exif_item))
        iloc = iso_fullbox(b"iloc", 0, 0, iloc_payload)
        return iso_fullbox(b"meta", 0, 0, hdlr + dinf + pitm + iinf + iref + iprp + iloc)

    meta_dummy = build_meta(0, 0)
    mdat_start = len(ftyp) + len(meta_dummy) + 8
    meta = build_meta(mdat_start, mdat_start + len(img_item))
    mdat = iso_box(b"mdat", img_item + exif_item)
    return ftyp + meta + mdat


def build_tiff_raw(spec: Dict[str, Any]) -> bytes:
    xmp = build_xmp_packet(product_name=spec["product_name"]) if spec.get("product_name") else None
    return build_tiff_exif(
        make=spec.get("make", ""),
        model=spec.get("model", ""),
        dto=exif_datetime_from_iso(spec["capture_dt"]),
        unique_camera_model=spec.get("unique_camera_model", ""),
        xmp_packet=xmp,
        include_image_ifd=True,
        cr2_header=bool(spec.get("cr2_header", False)),
    )


def build_mvhd(mac_seconds: int) -> bytes:
    payload = bytearray()
    payload += struct.pack(">IIII", mac_seconds, mac_seconds, 1000, 1000)
    payload += struct.pack(">IH", 0x00010000, 0x0100)
    payload += b"\x00" * 10
    for val in (0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000):
        payload += struct.pack(">I", val)
    payload += b"\x00" * 24
    payload += struct.pack(">I", 2)
    return iso_fullbox(b"mvhd", 0, 0, bytes(payload))


def build_qt_mdta_meta(entries: list[tuple[str, str]]) -> bytes:
    hdlr = iso_fullbox(b"hdlr", 0, 0, b"\x00\x00\x00\x00mdta" + b"\x00" * 12 + b"\x00")
    keys_payload = bytearray(struct.pack(">I", len(entries)))
    ilst_payload = bytearray()
    for index, (key, value) in enumerate(entries, start=1):
        key_bytes = key.encode("utf-8")
        keys_payload += struct.pack(">I4s", 8 + len(key_bytes), b"mdta") + key_bytes
        val_bytes = value.encode("utf-8")
        data_box = iso_box(b"data", struct.pack(">II", 1, 0) + val_bytes)
        ilst_payload += struct.pack(">II", 8 + len(data_box), index) + data_box
    keys = iso_fullbox(b"keys", 0, 0, bytes(keys_payload))
    ilst = iso_box(b"ilst", bytes(ilst_payload))
    return iso_box(b"meta", hdlr + keys + ilst)


def build_itunes_too_meta(encoder_name: str) -> bytes:
    hdlr = iso_fullbox(b"hdlr", 0, 0, b"\x00\x00\x00\x00mdirappl" + b"\x00" * 9)
    data_box = iso_box(b"data", struct.pack(">II", 1, 0) + encoder_name.encode("utf-8"))
    too_box = iso_box(b"\xa9too", data_box)
    ilst = iso_box(b"ilst", too_box)
    return iso_fullbox(b"meta", 0, 0, hdlr + ilst)


def build_gpmf_klv(key: bytes, typ: bytes, val: bytes) -> bytes:
    padded_len = ((len(val) + 3) // 4) * 4
    padded = val + b"\x00" * (padded_len - len(val))
    return struct.pack(">4s1sBH", key, typ, 1, len(val)) + padded


def build_mov(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"qt  \x00\x00\x00\x00qt  ")
    entries: list[tuple[str, str]] = []
    if spec.get("make"):
        entries.append(("com.apple.quicktime.make", spec["make"]))
    if spec.get("model"):
        entries.append(("com.apple.quicktime.model", spec["model"]))
    entries.append(("com.apple.quicktime.creationdate", spec["capture_dt"]))
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    meta = build_qt_mdta_meta(entries)
    return ftyp + iso_box(b"moov", mvhd + meta)


def build_m4a(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"M4A \x00\x00\x00\x00M4A mp42isom")
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    return ftyp + iso_box(b"moov", mvhd)


def build_gopro_mp4(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"mp42\x00\x00\x00\x01mp42isom")
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    gpmf_payload = (
        build_gpmf_klv(b"MINF", b"c", spec["model"].encode("utf-8"))
        + build_gpmf_klv(b"CASN", b"c", spec["serial"].encode("utf-8"))
    )
    udta = iso_box(b"udta", iso_box(b"GPMF", gpmf_payload))
    return ftyp + iso_box(b"moov", mvhd + udta)


def build_dji_mp4(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    xtra_text = f"model_name:{spec['model_code']};".encode("utf-16-le")
    xtra = iso_box(b"Xtra", xtra_text)
    udta_children = xtra
    if spec.get("encoder_name"):
        udta_children += build_itunes_too_meta(spec["encoder_name"])
    udta = iso_box(b"udta", udta_children)
    return ftyp + iso_box(b"moov", mvhd + udta)


def build_samsung_mp4(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"mp42\x00\x00\x00\x00mp42isom")
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    mdln = iso_box(b"mdln", spec["model"].encode("utf-8"))
    smta = iso_fullbox(b"smta", 0, 0, mdln)
    udta = iso_box(b"udta", smta)
    return ftyp + iso_box(b"moov", mvhd + udta)


def sony_nrt_xml(creation_dt: str, model_name: str, serial_no: str) -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">\n'
        f'\t<CreationDate value="{creation_dt}"/>\n'
        f'\t<Device manufacturer="Sony" modelName="{model_name}" serialNo="{serial_no}"/>\n'
        "</NonRealTimeMeta>\n"
    ).encode("utf-8")


def build_sony_mp4(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"XAVC\x01\x23\x00\x00XAVCmp42iso2")
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    moov = iso_box(b"moov", mvhd)
    xml_bytes = sony_nrt_xml(spec["capture_dt"], spec["model"], spec["serial"])
    xml_box = iso_fullbox(b"xml ", 0, 0, xml_bytes)
    meta = iso_fullbox(b"meta", 0, 0, xml_box)
    return ftyp + moov + meta


def build_insv(spec: Dict[str, Any]) -> bytes:
    ftyp = iso_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
    mvhd = build_mvhd(mp4_seconds_from_iso(spec["capture_dt"]))
    moov = iso_box(b"moov", mvhd)
    tail = f"TESTSERIAL0003\x00{spec['model']}\x00v1.0.59_build1\x00".encode("utf-8")
    return ftyp + moov + tail


def build_wav(_spec: Dict[str, Any]) -> bytes:
    # Minimal 44-byte RIFF/WAVE PCM header with 4 bytes of silence (48 bytes total).
    sample_bytes = b"\x00\x00\x00\x00"
    fmt_chunk = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, 48000, 96000, 2, 16)
    data_chunk = struct.pack("<4sI", b"data", len(sample_bytes)) + sample_bytes
    riff_body = b"WAVE" + fmt_chunk + data_chunk
    return struct.pack("<4sI", b"RIFF", len(riff_body)) + riff_body


def build_srt(spec: Dict[str, Any]) -> bytes:
    return (
        "1\n"
        "00:00:00,000 --> 00:00:00,033\n"
        f"{spec['srt_timestamp']}\n"
    ).encode("utf-8")


def build_xml(spec: Dict[str, Any]) -> bytes:
    return sony_nrt_xml(spec["capture_dt"], spec["model"], spec["serial"])


BUILDERS: Dict[str, Callable[[Dict[str, Any]], bytes]] = {
    "heic": build_heic,
    "jpg": build_jpeg,
    "png": build_png,
    "tiff_raw": build_tiff_raw,
    "mov": build_mov,
    "m4a": build_m4a,
    "mp4_gopro": build_gopro_mp4,
    "mp4_dji": build_dji_mp4,
    "mp4_samsung": build_samsung_mp4,
    "mp4_sony": build_sony_mp4,
    "insv": build_insv,
    "wav": build_wav,
    "srt": build_srt,
    "xml": build_xml,
}


SYNTHETIC_SPECS: Dict[str, Dict[str, Dict[str, Any]]] = {
    "SD_CARD1": {
        "DCIM/IMG_2940.HEIC": {"kind": "heic", "make": "Apple", "model": "iPhone 12 mini", "capture_dt": "2024-08-09T20:32:44+02:00"},
        "DCIM/IMG_8236.HEIC": {"kind": "heic", "make": "Apple", "model": "iPhone 13 Pro", "capture_dt": "2023-08-11T08:15:52+02:00"},
        "DCIM/IMG_8248.DNG": {"kind": "tiff_raw", "make": "Apple", "model": "iPhone 13 Pro", "capture_dt": "2023-08-11T16:27:23+02:00"},
        "DCIM/IMG_8249.MOV": {"kind": "mov", "make": "Apple", "model": "iPhone 13 Pro", "capture_dt": "2023-08-11T16:31:50+02:00"},
        "DCIM/IMG_0083.DNG": {"kind": "tiff_raw", "make": "Apple", "model": "iPhone 15 Pro", "capture_dt": "2024-09-19T08:20:28+02:00"},
        "DCIM/IMG_0168.MOV": {"kind": "mov", "make": "Apple", "model": "iPhone 12 mini", "capture_dt": "2024-03-23T12:53:55+01:00"},
        "DCIM/IMG_0187.HEIC": {"kind": "heic", "make": "Apple", "model": "iPhone 15 Pro", "capture_dt": "2024-09-20T19:07:58+02:00"},
        "DCIM/IMG_0245.MOV": {"kind": "mov", "make": "Apple", "model": "iPhone 16", "capture_dt": "2026-06-01T09:02:43+02:00"},
        "DCIM/IMG_0076.PNG": {"kind": "png", "make": "", "model": "", "capture_dt": "2024-09-18T20:30:33+02:00"},
        "DCIM/A001_06041206_C097.mov": {"kind": "mov", "make": "", "model": "Apple iPhone 15 Pro 13mm", "capture_dt": "2026-06-04T12:06:00+02:00"},
        "DCIM/iphone recording.m4a": {"kind": "m4a", "capture_dt": "2026-07-16T05:48:57+00:00"},
    },
    "SD_CARD2": {
        "DCIM/100MSDCF/DSC01930.JPG": {"kind": "jpg", "make": "SONY", "model": "DSC-RX100", "capture_dt": "2026-02-21T07:39:33+01:00"},
        "DCIM/100MSDCF/DSC02701.ARW": {"kind": "tiff_raw", "make": "SONY", "model": "DSC-RX100", "capture_dt": "2026-06-12T03:13:30+02:00"},
        "DCIM/100MSDCF/DSC00421.JPG": {"kind": "jpg", "make": "SONY", "model": "DSC-RX100M6", "capture_dt": "2023-05-10T12:20:36+02:00"},
        "DCIM/100MSDCF/DSC00421.ARW": {"kind": "tiff_raw", "make": "SONY", "model": "DSC-RX100M6", "capture_dt": "2023-05-10T12:20:36+02:00"},
        "DCIM/100MSDCF/DSC02577.ARW": {"kind": "tiff_raw", "make": "SONY", "model": "ILCE-7CM2", "capture_dt": "2026-06-01T18:15:01+02:00"},
        "DCIM/100MSDCF/DSC08259.ARW": {"kind": "tiff_raw", "make": "SONY", "model": "ILCE-6000", "capture_dt": "2026-03-02T15:22:57+01:00"},
        "DCIM/100MSDCF/DSC09387.ARW": {"kind": "tiff_raw", "make": "SONY", "model": "DSLR-A380", "capture_dt": "2024-02-15T18:34:39+01:00"},
        "DCIM/100CANON/IMG_1765.CR2": {"kind": "tiff_raw", "make": "Canon", "model": "Canon EOS 5D Mark II", "capture_dt": "2026-06-05T01:38:05+02:00", "cr2_header": True},
        "DCIM/100GOPRO/G0010306.JPG": {"kind": "jpg", "make": "GoPro", "model": "HERO10 Black", "capture_dt": "2024-09-07T00:05:32+02:00"},
        "DCIM/100GOPRO/G0010306.GPR": {"kind": "tiff_raw", "make": "GoPro", "model": "HERO10 Black", "capture_dt": "2024-09-07T00:05:32+02:00"},
        "DCIM/100GOPRO/G0010044.JPG": {"kind": "jpg", "make": "GoPro", "model": "HERO10 Black", "capture_dt": "2024-03-02T15:16:11+01:00"},
        "DCIM/100GOPRO/G0010044.GPR": {"kind": "tiff_raw", "make": "GoPro", "model": "HERO10 Black", "capture_dt": "2024-03-02T15:16:11+01:00"},
        "DCIM/100GOPRO/GX010645.MP4": {"kind": "mp4_gopro", "model": "HERO10 Black", "serial": "TESTSERIAL0002", "capture_dt": "2024-09-15T14:53:13+02:00"},
        "DCIM/100GOPRO/GX020024.MP4": {"kind": "mp4_gopro", "model": "HERO10 Black", "serial": "TESTSERIAL0002", "capture_dt": "2024-02-25T15:18:00+01:00"},
        "DCIM/100MEDIA/DJI_20240218122338_0019_D.JPG": {"kind": "jpg", "make": "DJI", "model": "AC003", "unique_camera_model": "DJI AC003 OsmoAction4", "product_name": "OsmoAction4", "capture_dt": "2024-02-18T12:23:38+01:00"},
        "DCIM/100MEDIA/DJI_20240218140744_0024_D.DNG": {"kind": "tiff_raw", "make": "DJI", "model": "AC003", "unique_camera_model": "DJI AC003 OsmoAction4", "product_name": "OsmoAction4", "capture_dt": "2024-02-18T14:07:44+01:00"},
        "DCIM/100MEDIA/DJI_20240204134712_0013_D.MP4": {"kind": "mp4_dji", "model_code": "AC003", "encoder_name": "DJI OsmoAction4", "capture_dt": "2024-02-04T12:47:13+01:00"},
        "DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4": {"kind": "mp4_dji", "model_code": "AC006", "encoder_name": "DJI OsmoAction6", "capture_dt": "2026-06-13T10:27:15+02:00"},
        "DCIM/DJI_001/DJI_20260523115129_0558_D.DNG": {"kind": "tiff_raw", "make": "DJI", "model": "FC8482", "unique_camera_model": "DJI FC8482", "product_name": "Mini4 Pro", "capture_dt": "2026-05-23T11:51:29+02:00"},
        "DCIM/DJI_001/DJI_20260523115257_0565_D.MP4": {"kind": "mp4_dji", "model_code": "FC8482", "encoder_name": "DJI Mini4 Pro", "capture_dt": "2026-05-23T09:52:57+00:00"},
        "DCIM/DJI_001/DJI_20260523115257_0565_D.SRT": {"kind": "srt", "srt_timestamp": "2026-05-23 11:52:57.533", "capture_dt": "2026-05-23T09:52:57+00:00"},
        "DCIM/DJI_001/DJI_20240126194607_0117_D.JPG": {"kind": "jpg", "make": "DJI", "model": "PP-101", "unique_camera_model": "DJI PP-101 OsmoPocket3", "product_name": "OsmoPocket3", "capture_dt": "2024-01-26T19:46:07+01:00"},
        "DCIM/DJI_001/DJI_20240126194607_0117_D.DNG": {"kind": "tiff_raw", "make": "DJI", "model": "PP-101", "unique_camera_model": "DJI PP-101 OsmoPocket3", "product_name": "OsmoPocket3", "capture_dt": "2024-01-26T19:46:07+01:00"},
        "DCIM/DJI_001/DJI_20240126093104_0012_D.MP4": {"kind": "mp4_dji", "model_code": "PP-101", "encoder_name": "DJI OsmoPocket3", "capture_dt": "2024-01-26T09:31:04+01:00"},
        "DCIM/DJI_001/DJI_20240126093104_0012_D.WAV": {"kind": "wav", "capture_dt": "2024-01-26T09:31:04+01:00"},
        "DCIM/CAMERA/20240809_160800.jpg": {"kind": "jpg", "make": "samsung", "model": "Galaxy A54 5G", "capture_dt": "2024-08-09T16:08:00+02:00"},
        "DCIM/CAMERA/20240809_164400.mp4": {"kind": "mp4_samsung", "model": "SM-A546B", "capture_dt": "2024-08-09T16:44:00+02:00"},
        "DCIM/EXPORT/DJI_20240908175300_0011_D.JPG": {"kind": "jpg", "make": "DJI", "model": "FC8482", "product_name": "Mini4 Pro", "capture_dt": "2024-09-08T17:53:00+02:00"},
        "DCIM/Camera01/VID_20231023_055225_00_645.insv": {"kind": "insv", "model": "Insta360 ONE X2", "capture_dt": "2023-10-23T05:52:15+02:00"},
        "PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4": {"kind": "mp4_sony", "model": "ILCE-7CM2", "serial": "4294967295", "capture_dt": "2025-08-24T12:34:52+02:00"},
        "PRIVATE/M4ROOT/CLIP/20260618_C5262.MP4": {"kind": "mp4_sony", "model": "ILCE-7CM2", "serial": "4294967295", "capture_dt": "2026-06-18T08:05:48-05:00"},
        "PRIVATE/M4ROOT/CLIP/20260618_C5262M01.XML": {"kind": "xml", "model": "ILCE-7CM2", "serial": "4294967295", "capture_dt": "2026-06-18T08:05:48-05:00"},
    },
}


def resolve_source_dir() -> Optional[Path]:
    override = os.environ.get("FYLURO_FIXTURE_SOURCE_DIR")
    if not override:
        print("error: set FYLURO_FIXTURE_SOURCE_DIR to a local real-media directory", file=sys.stderr)
        return None
    return Path(override).expanduser()


def validate_metadata(source_dir: Path) -> int:
    """Best-effort check that real media files carry capture metadata."""
    exiftool = shutil.which("exiftool")
    if exiftool is None:
        print("note: exiftool not found; skipping capture-metadata validation")
        return 0
    failures = 0
    for mapping in CARD_MAPPINGS.values():
        for source_relative in mapping:
            source_path = source_dir / source_relative
            ext = source_path.suffix.lower().lstrip(".")
            if ext in PHOTO_EXTENSIONS:
                tag = "DateTimeOriginal"
            elif ext in VIDEO_EXTENSIONS or (ext in AUDIO_EXTENSIONS and ext != "wav"):
                tag = "CreateDate"
            else:
                continue
            result = subprocess.run(
                [exiftool, "-s3", f"-{tag}", str(source_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            if not result.stdout.strip():
                print(f"warning: {source_relative}: missing {tag}")
                failures += 1
    return failures


def prepare_card_targets(card_names: Any, manifest_path: Path, force: bool) -> bool:
    for card_name in card_names:
        card_root = TESTING_DIRS / card_name
        if card_root.exists():
            if not force and manifest_path.is_file():
                print(f"{card_name} already exists; use --check to verify or --force to rebuild")
                return False
            shutil.rmtree(card_root)
    return True


def build_synthetic(force: bool, update_manifest: bool) -> int:
    if not prepare_card_targets(SYNTHETIC_SPECS.keys(), SYNTHETIC_MANIFEST_PATH, force=force):
        return 1

    manifest: Dict[str, Dict[str, Any]] = {}
    for card_name, specs in SYNTHETIC_SPECS.items():
        card_root = TESTING_DIRS / card_name
        total_bytes = 0
        for card_relative, spec in specs.items():
            dest_path = card_root / card_relative
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            payload = BUILDERS[spec["kind"]](spec)
            dest_path.write_bytes(payload)
            ts = parse_iso_utc(spec["capture_dt"]).timestamp()
            os.utime(dest_path, (ts, ts))
            manifest[f"{card_name}/{card_relative}"] = {
                "size": len(payload),
                "sha256": sha256_of(dest_path),
            }
            total_bytes += len(payload)
        print(f"built synthetic {card_name}: {len(specs)} files, {total_bytes / 1024:.1f} KB")

    if update_manifest or not SYNTHETIC_MANIFEST_PATH.is_file():
        SYNTHETIC_MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"wrote {SYNTHETIC_MANIFEST_PATH.relative_to(REPO_ROOT)} ({len(manifest)} entries)")
        return 0

    return check(SYNTHETIC_MANIFEST_PATH)


def build_real(source_dir: Path, force: bool) -> int:
    missing = [
        source_relative
        for mapping in CARD_MAPPINGS.values()
        for source_relative in mapping
        if not (source_dir / source_relative).is_file()
    ]
    if missing:
        print(f"error: fixture source dir {source_dir} is missing {len(missing)} file(s):", file=sys.stderr)
        for source_relative in missing:
            print(f"  {source_relative}", file=sys.stderr)
        return 1

    if not prepare_card_targets(CARD_MAPPINGS.keys(), REAL_MANIFEST_PATH, force=force):
        return 1

    validate_metadata(source_dir)

    manifest = {}
    for card_name, mapping in CARD_MAPPINGS.items():
        card_root = TESTING_DIRS / card_name
        for source_relative, card_relative in mapping.items():
            source_path = source_dir / source_relative
            dest_path = card_root / card_relative
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, dest_path)
            manifest[f"{card_name}/{card_relative}"] = {
                "size": dest_path.stat().st_size,
                "sha256": sha256_of(dest_path),
            }
        total_bytes = sum(
            manifest[f"{card_name}/{card_relative}"]["size"] for card_relative in mapping.values()
        )
        print(f"built real {card_name}: {len(mapping)} files, {total_bytes / 1_000_000:.0f} MB")

    REAL_MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {REAL_MANIFEST_PATH.relative_to(REPO_ROOT)} ({len(manifest)} entries)")
    return 0


def check(manifest_path: Path) -> int:
    if not manifest_path.is_file():
        print(f"error: missing manifest {manifest_path}; run the build first", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())
    problems = []
    for manifest_relative, expected in manifest.items():
        path = TESTING_DIRS / manifest_relative
        if not path.is_file():
            problems.append(f"missing: {manifest_relative}")
        elif path.stat().st_size != expected["size"]:
            problems.append(f"size mismatch: {manifest_relative}")
        elif sha256_of(path) != expected["sha256"]:
            problems.append(f"hash mismatch: {manifest_relative}")
    for card_name in CARD_MAPPINGS:
        card_root = TESTING_DIRS / card_name
        if not card_root.is_dir():
            continue
        for path in card_root.rglob("*"):
            if path.is_file() and path.name != ".DS_Store":
                manifest_relative = str(path.relative_to(TESTING_DIRS))
                if manifest_relative not in manifest:
                    problems.append(f"unexpected file: {manifest_relative}")
    if problems:
        print("fixture check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"fixture check passed ({len(manifest)} files)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--synthetic",
        action="store_true",
        help="build tiny deterministic synthetic cards (default when --real is omitted)",
    )
    mode_group.add_argument(
        "--real",
        action="store_true",
        help="build cards from the local real-media directory and track in fixture-manifest.real.json",
    )
    parser.add_argument("--check", action="store_true", help="verify built cards against the manifest")
    parser.add_argument("--force", action="store_true", help="rebuild even if cards already exist")
    parser.add_argument(
        "--update-manifest",
        action="store_true",
        help="update Tests/TestingDirs/fixture-manifest.json when building synthetic cards",
    )
    args = parser.parse_args()
    manifest_path = REAL_MANIFEST_PATH if args.real else SYNTHETIC_MANIFEST_PATH
    if args.check:
        return check(manifest_path)
    if args.real:
        source_dir = resolve_source_dir()
        if source_dir is None:
            return 1
        return build_real(source_dir, force=args.force)
    return build_synthetic(force=args.force, update_manifest=args.update_manifest)


if __name__ == "__main__":
    sys.exit(main())
