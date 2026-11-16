"""Exercise the compiled production C code. No Apple device or account is used."""
import ctypes as C
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CPU_ARM64 = 0x0100000C


class Info(C.Structure):
    _fields_ = [("is_macho", C.c_bool), ("is_fat", C.c_bool),
                ("slices", C.c_uint32), ("arm64_slices", C.c_uint32),
                ("encrypted", C.c_bool), ("cpu", C.c_uint32), ("subtype", C.c_uint32),
                ("cryptoff", C.c_uint32), ("cryptsize", C.c_uint32), ("cryptid", C.c_uint32)]


class SigningSlice(C.Structure):
    _fields_ = [("cpu", C.c_uint32), ("subtype", C.c_uint32)] + [
        (name, C.c_uint64) for name in ("offset", "size", "signature_offset", "signature_size",
        "signature_fields", "linkedit_vmsize", "linkedit_filesize")
    ] + [("linkedit_word_size", C.c_uint32)]


def macho(size=0x8000, cpu=CPU_ARM64, cryptid=1):
    header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
    command = struct.pack("<6I", 0x2C, 24, 0x4000, size, cryptid, 0)
    text = bytes((i % 251 for i in range(size)))
    return header + command + bytes(0x4000 - 56) + text


def signed_macho():
    header = struct.pack("<8I", 0xFEEDFACF, CPU_ARM64, 0, 6, 3, 112, 0, 0)
    encryption = struct.pack("<6I", 0x2C, 24, 0x4000, 0x4000, 1, 0)
    linkedit = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0x100008000,
                           0x4000, 0x8000, 64, 1, 1, 0, 0)
    signature = struct.pack("<4I", 0x1D, 16, 0x8000, 64)
    return header + encryption + linkedit + signature + bytes(0x4000 - 144) + bytes([0xA5]) * 0x4000 + bytes([0x5A]) * 64


class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.library = Path(cls.build.name) / ("core.dylib" if sys.platform == "darwin" else "core.so")
        command = [os.environ.get("CC", "cc"), "-std=c11", "-D_DEFAULT_SOURCE", "-DFP_TESTING",
                   "-Wall", "-Wextra", "-Werror", "-Wno-format-truncation", "-shared", "-fPIC",
                   str(ROOT / "Core/FPCore.c"), str(ROOT / "Tests/kernel_stub.c"),
                   "-lz", "-o", str(cls.library)]
        # clang does not recognize GCC's format-truncation warning.
        if sys.platform == "darwin": command.remove("-Wno-format-truncation")
        subprocess.run(command, check=True)
        cls.lib = C.CDLL(str(cls.library))
        cls.lib.fp_probe.argtypes = [C.c_char_p, C.POINTER(Info)]
        cls.lib.fp_signing_layout.argtypes = [C.c_char_p, C.POINTER(SigningSlice), C.c_uint32,
                                             C.POINTER(C.c_uint32), C.c_char_p, C.c_size_t]
        cls.lib.fp_decrypt_copy.argtypes = [C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t,
                                          C.c_char_p, C.c_size_t]
        cls.lib.fp_decrypt_file.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t]
        for name in ("fp_unzip", "fp_zip_dir"):
            getattr(cls.lib, name).argtypes = [C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t]

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.lib.fp_test_reset(0)

    def probe(self, path):
        info = Info()
        return self.lib.fp_probe(os.fsencode(path), C.byref(info)), info

    def decrypt(self, data, mode=0):
        source, output = self.root / "input", self.root / "output"
        source.write_bytes(data)
        source.chmod(0o755)
        output.write_bytes(b"previous successful output")
        self.lib.fp_test_reset(mode)
        log, error = C.create_string_buffer(16384), C.create_string_buffer(512)
        rc = self.lib.fp_decrypt_copy(os.fsencode(source), os.fsencode(output), log, len(log), error, len(error))
        self.assertEqual(source.read_bytes(), data)
        self.assertFalse(list(self.root.glob("*.fpdec.*")))
        return rc, output, log.value, error.value

    def archive(self, name, entries, compression=zipfile.ZIP_DEFLATED):
        file = self.root / name
        with zipfile.ZipFile(file, "w", compression) as archive:
            for path, content, mode in entries:
                info = zipfile.ZipInfo(path)
                info.create_system = 3
                info.external_attr = mode << 16
                info.compress_type = compression
                archive.writestr(info, content)
        return file

    def extract(self, archive, destination=None):
        destination = destination or self.root / "unpacked"
        error = C.create_string_buffer(512)
        rc = self.lib.fp_unzip(os.fsencode(archive), os.fsencode(destination), error, len(error))
        return rc, destination, error.value

    def test_decrypts_only_encrypted_range_and_clears_header(self):
        data = macho()
        rc, output, _, error = self.decrypt(data)
        self.assertEqual(rc, 0, error)
        expected = bytearray(data)
        expected[48:52] = bytes(4)
        expected[0x4000:] = bytes(byte ^ 0xA5 for byte in data[0x4000:])
        self.assertEqual(output.read_bytes(), expected)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o755)
        self.assertFalse(self.probe(output)[1].encrypted)

    def test_refusal_unchanged_pages_and_lazy_read_errors_never_replace_output(self):
        for mode, expected in [(1, b"errno"), (2, b"unchanged"), (3, b"page-in")]:
            with self.subTest(mode=mode):
                rc, output, _, error = self.decrypt(macho(), mode)
                self.assertEqual(rc, -1)
                self.assertIn(expected, error)
                self.assertEqual(output.read_bytes(), b"previous successful output")

    def test_large_range_remaps_each_window_once(self):
        rc, _, _, error = self.decrypt(macho(size=(16 << 20) + 0x4000))
        self.assertEqual(rc, 0, error)
        self.assertEqual(self.lib.fp_test_calls(), 2)

    def test_fat_slice_uses_its_file_offset(self):
        thin = macho()
        offset = 0x8000
        data = struct.pack(">II", 0xCAFEBABE, 1)
        data += struct.pack(">IIIII", CPU_ARM64, 0, offset, len(thin), 14)
        data += bytes(offset - len(data)) + thin
        rc, output, _, error = self.decrypt(data)
        self.assertEqual(rc, 0, error)
        self.assertEqual(output.read_bytes()[offset + 0x4000:],
                         bytes(byte ^ 0xA5 for byte in thin[0x4000:]))

    def test_bad_range_and_unsupported_encrypted_architecture_fail(self):
        malformed = bytearray(macho())
        struct.pack_into("<I", malformed, 44, 0xFFFFFFFF)
        for data in (malformed, macho(cpu=0x01000007)):
            rc, output, _, _ = self.decrypt(data)
            self.assertEqual(rc, -1)
            self.assertEqual(output.read_bytes(), b"previous successful output")

    def test_plain_input_is_copied_without_kernel_calls(self):
        data = macho(cryptid=0)
        rc, output, _, error = self.decrypt(data)
        self.assertEqual(rc, 0, error)
        self.assertEqual(output.read_bytes(), data)
        self.assertEqual(self.lib.fp_test_calls(), 0)

    def test_signing_layout_masks_only_signature_fields(self):
        file = self.root / "signed"
        file.write_bytes(signed_macho())
        records, count, error = (SigningSlice * 8)(), C.c_uint32(), C.create_string_buffer(512)
        rc = self.lib.fp_signing_layout(os.fsencode(file), records, 8, C.byref(count), error, len(error))
        self.assertEqual(rc, 0, error.value)
        self.assertEqual(count.value, 1)
        record = records[0]
        self.assertEqual((record.signature_offset, record.signature_size), (0x8000, 64))
        self.assertEqual((record.signature_fields, record.linkedit_vmsize, record.linkedit_filesize), (136, 88, 104))
        self.assertEqual(record.linkedit_word_size, 8)

    def test_signature_cannot_hide_encrypted_pages(self):
        data = bytearray(signed_macho())
        struct.pack_into("<I", data, 136, 0x4000)
        file = self.root / "overlap"
        file.write_bytes(data)
        records, count, error = (SigningSlice * 8)(), C.c_uint32(), C.create_string_buffer(512)
        rc = self.lib.fp_signing_layout(os.fsencode(file), records, 8, C.byref(count), error, len(error))
        self.assertEqual(rc, -1)
        self.assertIn(b"overlaps", error.value)

    def test_native_zip_round_trip_preserves_bytes_modes_links_unicode_and_empty_dirs(self):
        archive = self.archive("source.ipa", [
            ("Payload/Test.app/empty/", b"", stat.S_IFDIR | 0o755),
            ("Payload/Test.app/Test", macho(), stat.S_IFREG | 0o755),
            ("Payload/Test.app/名前.txt", b"resource", stat.S_IFREG | 0o644),
            ("Payload/Test.app/alias", b"Test", stat.S_IFLNK | 0o777)])
        rc, extracted, error = self.extract(archive)
        self.assertEqual(rc, 0, error)
        self.assertEqual(os.readlink(extracted / "Payload/Test.app/alias"), "Test")
        repacked = self.root / "repacked.ipa"
        error_buffer = C.create_string_buffer(512)
        rc = self.lib.fp_zip_dir(os.fsencode(extracted), os.fsencode(repacked), error_buffer, len(error_buffer))
        self.assertEqual(rc, 0, error_buffer.value)
        with zipfile.ZipFile(repacked) as result:
            self.assertIsNone(result.testzip())
            self.assertEqual(result.read("Payload/Test.app/Test"), macho())
            self.assertEqual(result.read("Payload/Test.app/名前.txt"), b"resource")
            self.assertTrue(stat.S_ISLNK(result.getinfo("Payload/Test.app/alias").external_attr >> 16))
            self.assertIn("Payload/Test.app/empty/", result.namelist())
        rc, second, error = self.extract(repacked, self.root / "second")
        self.assertEqual(rc, 0, error)
        self.assertEqual((second / "Payload/Test.app/alias").read_bytes(), macho())

    def test_unsafe_paths_and_links_are_rejected(self):
        for path, target, mode in [("../escape", b"bad", stat.S_IFREG | 0o644),
                                   ("Payload/link", b"../../escape", stat.S_IFLNK | 0o777)]:
            with self.subTest(path=path):
                archive = self.archive("unsafe.ipa", [(path, target, mode)])
                self.assertEqual(self.extract(archive)[0], -1)
                self.assertFalse((self.root / "escape").exists())

    def test_crc_corruption_is_rejected(self):
        archive = self.archive("crc.ipa", [("file", b"hello", stat.S_IFREG | 0o644)], zipfile.ZIP_STORED)
        data = bytearray(archive.read_bytes())
        data[data.index(b"hello")] ^= 1
        archive.write_bytes(data)
        self.assertEqual(self.extract(archive)[0], -1)

    def test_symlink_chains_cannot_escape_the_extraction_root(self):
        archive = self.archive("links.ipa", [
            ("a", b".", stat.S_IFLNK | 0o777),
            ("link", b"a/../outside", stat.S_IFLNK | 0o777)])
        self.assertEqual(self.extract(archive)[0], -1)


if __name__ == "__main__":
    unittest.main()
