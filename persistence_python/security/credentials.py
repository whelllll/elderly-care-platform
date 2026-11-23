"""离线生成28套密码，以Windows当前用户DPAPI加密保存；不连接数据库。"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import secrets

MAGIC = b"B3-DPAPI-1\n"


def _slots(entries):
    # 离线准备只绑定28个password_env槽位；模板的实际身份允许尚未确认。
    # 改密/验收入口仍强制检查完整expected，不能凭模板执行数据库操作。
    from .accounts import validate_entries
    if not isinstance(entries, list):
        raise ValueError("B3凭据槽位必须是28项清单。")
    return validate_entries([{key: value for key, value in entry.items() if key != "expected"}
                             if isinstance(entry, dict) else entry for entry in entries])


def external_path(path):
    target = Path(path).expanduser().resolve()
    if any((parent / ".git").exists() for parent in (target.parent, *target.parents)):
        raise ValueError("凭据文件必须位于Git仓库之外。")
    return target


def _dpapi(data, *, decrypt=False):
    if os.name != "nt":
        raise ValueError("凭据文件需要Windows当前用户DPAPI，不提供明文降级。")
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.c_void_p)]

    buffer = ctypes.create_string_buffer(data)
    source, output = Blob(len(data), ctypes.cast(buffer, ctypes.c_void_p)), Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    function = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                         ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    # CRYPTPROTECT_UI_FORBIDDEN；不使用LOCAL_MACHINE，密文绑定当前Windows用户。
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(output)):
        raise ValueError("凭据加解密失败；请使用创建文件的Windows用户。")
    try:
        return ctypes.string_at(output.data, output.size)
    finally:
        if decrypt:
            ctypes.memset(output.data, 0, output.size)
        kernel.LocalFree(output.data)


def generate_passwords(entries):
    from .accounts import validate_credentials
    _slots(entries)
    values, seen = {}, set()
    for entry in entries:
        for _ in range(100):
            password = secrets.token_urlsafe(24)
            if password not in seen and password != "Admin@123":
                break
        else:
            raise ValueError("无法生成独立密码，未保存凭据。")
        seen.add(password)
        values[entry["password_env"]] = password
    validate_credentials({entry["username"]: values[entry["password_env"]] for entry in entries})
    return values


def create_credential_file(entries, path):
    target = external_path(path)
    values = generate_passwords(entries)
    payload = json.dumps({"version": 1, "passwords": values}).encode("utf-8")
    protected = MAGIC + _dpapi(payload)
    target.parent.mkdir(parents=True, exist_ok=True)
    # 只创建新文件，拒绝覆盖现有密码；落盘内容始终是密文。
    with target.open("xb") as stream:
        stream.write(protected)
    return {"accounts": 28, "encrypted": True, "database_accessed": False}


def load_credentials(entries, path):
    from .accounts import validate_credentials
    _slots(entries)
    try:
        content = external_path(path).read_bytes()
        if not content.startswith(MAGIC):
            raise ValueError()
        document = json.loads(_dpapi(content[len(MAGIC):], decrypt=True))
        values = document["passwords"]
        if set(document) != {"version", "passwords"} or document["version"] != 1:
            raise ValueError()
        if set(values) != {entry["password_env"] for entry in entries}:
            raise ValueError()
        credentials = {entry["username"]: values[entry["password_env"]] for entry in entries}
        validate_credentials(credentials)
        return credentials
    except Exception:
        raise ValueError("无法读取凭据文件，或文件与28个凭据槽位不匹配。") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True, help="仓库外新建的DPAPI凭据文件；禁止覆盖")
    args = parser.parse_args()
    try:
        with open(args.manifest, encoding="utf-8-sig") as stream:
            manifest = json.load(stream)
        if not isinstance(manifest, dict) or set(manifest) != {"accounts"}:
            raise ValueError("清单根对象仅允许accounts字段。")
        print(json.dumps(create_credential_file(manifest["accounts"], args.output)))
    except Exception:
        raise SystemExit("凭据生成失败；检查Windows用户、仓库外路径和文件是否已存在。") from None


if __name__ == "__main__":
    main()
