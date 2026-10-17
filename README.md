# gost-proxy-setup

用 Docker Compose + [gost](https://github.com/go-gost/gost) 一键部署带认证的 SOCKS5 代理,适合在服务器上做固定出口 IP 的测试。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/prehisle/gost-proxy-setup/main/install.sh | bash
```

只允许指定 IP 访问(推荐):

```bash
curl -fsSL https://raw.githubusercontent.com/prehisle/gost-proxy-setup/main/install.sh | bash -s -- --allow-ip 你的公网IP
```

脚本会:

1. 安装 Docker(未安装时使用 get.docker.com 官方脚本)。
2. 在 `/opt/gost`(可用 `--dir` 修改)生成随机密码,写入 `.env`(权限 600)和 `docker-compose.yml`。
3. 启动容器并在本机做一次出口 IP 自测。
4. 打印连接信息。

重复运行会保留已有的密码。

## 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--dir DIR` | `/opt/gost` | 安装目录 |
| `--port PORT` | `1080` | 对外端口 |
| `--user NAME` | `proxy` | 用户名 |
| `--allow-ip IP` | 不限制 | 只允许该 IP 访问,可重复指定 |
| `--uninstall` | | 停止并删除容器,保留目录和 `.env` |

## 安全说明

- **SOCKS5 不加密**,账号密码和流量明文传输。仅适合短期测试。
- Docker 发布的端口会**绕过 ufw**。`--allow-ip` 通过 `DOCKER-USER` 链限制访问,但 iptables 规则重启后可能失效,需要自行持久化。
- 云厂商的安全组同样建议只放行你自己的 IP。
- 仓库中不包含任何密码或服务器信息。
