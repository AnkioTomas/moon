# crypto

纯 LuaJIT，零外部依赖。无状态，全是模块函数，没有 `new()`。

没有 `init.lua`。按文件名引用，不要加 `crypto/init.lua`。

```lua
local Aes = require("crypto.aes")
local Sha256 = require("crypto.sha256")
local Rsa = require("crypto.rsa")
```

密钥、摘要、密文、签名都是原始字节（Lua string）。十六进制自己用 `crypto.hex` 转。这里不解析 PEM / ASN.1。

## 目录

| 文件 | 模块 | 做什么 |
|---|---|---|
| `md5.lua` / `sha1.lua` / `sha256.lua` / `sm3.lua` | `crypto.md5` 等 | 散列 |
| `aes.lua` | `crypto.aes` | AES-128/192/256，ECB / CBC |
| `sm4.lua` | `crypto.sm4` | SM4，ECB / CBC |
| `sm2.lua` | `crypto.sm2` | SM2 签名、公钥加密 |
| `rsa.lua` | `crypto.rsa` | RSA PKCS#1 v1.5 |
| `hex.lua` / `pad.lua` | `crypto.hex` / `crypto.pad` | 十六进制、PKCS#7 |
| `bn.lua` | `crypto.bn` | 奇数模运算，只给 SM2 / RSA 用 |

测试在 `tests/crypto/`，与这里镜像。

## 散列

`Md5`、`Sha1`、`Sha256`、`Sm3` 的接口一样：

| 函数 | 返回 |
|---|---|
| `hash(msg)` | 原始字节。MD5 16、SHA-1 20、SHA-256 / SM3 32 |
| `hex(msg)` | 小写十六进制 |

## AES / SM4

```lua
Aes.ecb_encrypt(data, key, pad)
Aes.ecb_decrypt(data, key, pad)
Aes.cbc_encrypt(data, key, iv, pad)
Aes.cbc_decrypt(data, key, iv, pad)
```

SM4 同名函数在 `Sm4` 上。

- AES 密钥 16 / 24 / 32 字节。SM4 密钥 16 字节。IV 都是 16 字节。
- `pad` 缺省走 PKCS#7。`pad == false` 表示数据已经按 16 字节对齐，原样加解密。
- `Aes.pkcs7_pad`、`Aes.pkcs7_unpad`、`Aes.from_hex`、`Aes.to_hex` 就是 `Pad` / `Hex` 的同一批函数。旧的京东读、番茄调用不用改。

`Pad.pkcs7_pad(data, block)` / `Pad.pkcs7_unpad(data, block)` 的 `block` 缺省 16。去填充只看最后一个字节给出的长度，不逐字节核对填充内容。这是旧 AES 的行为。

`Hex.to_hex` 输出小写。`Hex.from_hex` 先去掉空白；奇数个十六进制字符时，末位原样留下。

## SM2

曲线 `sm2p256v1`。私钥、标量都是 32 字节。

| 函数 | 结果 |
|---|---|
| `Sm2.public_key(d)` | 65 字节公钥，`04\|\|X\|\|Y` |
| `Sm2.keypair()` | `d, pub` |
| `Sm2.sign(msg, d, id, k)` | 64 字节 `r\|\|s` |
| `Sm2.verify(msg, sig, pub, id)` | 布尔 |
| `Sm2.encrypt(msg, pub, k)` | `C1\|\|C3\|\|C2` |
| `Sm2.decrypt(ct, d)` | 明文 |

- 用户标识 `id` 缺省 `1234567812345678`。
- 公钥接受 65 字节（带 `04`）或 64 字节 `X\|\|Y`。
- 密文里的 C1 固定是 `04\|\|X\|\|Y`（65 字节），C3 是 32 字节 SM3。解密只认这种密文。
- `k` 缺省读 `/dev/urandom`。测试传入 32 字节即可固定结果。

没有密钥协商。

## RSA

PKCS#1 v1.5。`n`、`e`、`d` 是无符号大端，高位为 0 的符号字节不要带上。`n` 的长度是偶数，且首字节不能是 0。密文和签名与 `n` 等长。

| 函数 | 说明 |
|---|---|
| `Rsa.encrypt(msg, n, e, rng)` | 类型 2 填充。`e` 缺省 65537（`\1\0\1`） |
| `Rsa.decrypt(ct, n, d)` | 明文 |
| `Rsa.sign(msg, n, d, hash)` | EMSA。`hash` 为 `md5` / `sha1` / `sha256`，缺省 `sha256` |
| `Rsa.verify(msg, sig, n, e, hash)` | 布尔。长度不对会报错，内容不匹配返回 false |
| `Rsa.keypair(bits, e)` | 返回 `n, e, d` |

- 明文最长 `#n - 11`（`00 02`、至少 8 字节非 0 填充、`00`）。签名侧同理，模必须装得下 DigestInfo。
- `rng(n)` 必须返回恰好 `n` 个非 0 字节。缺省读 `/dev/urandom`。
- `bits` 是 32 的倍数，512 到 4096。两个素数各占一半位数。

## bn

`Bn.modulus(mod_be)` 建一个奇数模上的运算。模是大端，字节数必须是偶数。元素长度等于模。

SM2 的域和阶是 32 字节素数，可以用 `inv`。RSA 的模是合数，只能用 `pow`。`inv` 走费马小定理，对合数不成立。

业务代码直接用 `crypto.sm2` / `crypto.rsa`，不要自己摸 `bn`。
