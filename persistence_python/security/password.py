"""兼容成员4现有Base64盐及PBKDF2-HMAC-SHA256，固定100000轮。"""
import base64
import binascii
import hashlib
import hmac
import secrets

ITERATIONS = 100_000


def hash_password(password):
    if not isinstance(password, str) or len(password) < 8:
        raise ValueError("密码至少8个字符。")
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, ITERATIONS)
    return base64.b64encode(digest).decode(), base64.b64encode(salt).decode()


def verify_password(password, password_hash, password_salt):
    if not isinstance(password, str):
        return False
    try:
        salt = base64.b64decode(password_salt, validate=True)
        expected = base64.b64decode(password_hash, validate=True)
        if len(salt) != 16 or len(expected) != 32:
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, ITERATIONS)
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError, binascii.Error):
        return False
