<p align="center">
<img src="https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/docs/logo.png" width="120" alt="Mihomo Logo">
</p>

<h3 align="center">
A high-performance, multi-protocol Mihomo (Clash Meta) proxy client in Docker, optimized for MikroTik RouterOS v7.
</h3>

<p align="center">
Высокопроизводительный многопротокольный прокси-клиент Mihomo (Clash Meta) в Docker-контейнере, специально оптимизированный для MikroTik RouterOS v7.
</p>

<p align="center">
<a href="https://hub.docker.com/r/wiktorbgu/mihomo-mikrotik">
<img src="https://img.shields.io/docker/pulls/wiktorbgu/mihomo-mikrotik?style=flat-square&logo=docker&logoColor=white" alt="Docker Pulls">
</a>
<a href="https://hub.docker.com/r/wiktorbgu/mihomo-mikrotik">
<img src="https://img.shields.io/docker/stars/wiktorbgu/mihomo-mikrotik?style=flat-square&logo=docker&logoColor=white" alt="Docker Stars">
</a>
<a href="https://github.com/wiktorbgu/mihomo-mikrotik">
<img src="https://img.shields.io/github/stars/wiktorbgu/mihomo-mikrotik?style=flat-square&logo=github" alt="GitHub Stars">
</a>
<a href="https://t.me/it_network_people">
<img src="https://img.shields.io/badge/Telegram-Community-purple?style=flat-square&logo=telegram&logoColor=white" alt="Telegram Community">
</a>
<a href="https://telegra.ph/Youre-making-the-world-a-better-place-11-24">
<img src="https://img.shields.io/badge/Donate-Support%20the%20Developer-green?style=flat-square&logo=heart&logoColor=white" alt="Donate">
</a>
</p>

### 📚 Documentation

<p>
  <a href="https://hub.docker.com/r/wiktorbgu/mihomo-mikrotik">
    <img src="https://img.shields.io/badge/Docker%20Hub-Image%20%26%20Usage-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker Hub">
  </a>
</p>

<p>
  <a href="https://github.com/wiktorbgu/mihomo-mikrotik/wiki">
    <img src="https://img.shields.io/badge/GitHub-Wiki-181717?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Wiki">
  </a>
</p>

## 🐳 Варианты сборок Docker

| Сборка | Размер на диске | Docker tag | Описание |
|:---|---:|:---|:---|
| 👀 Standard | **64 МБ** | `latest` | Рекомендуется большинству пользователей |
| 🌚 gVisor | **73,3 МБ** | `gvisor` | Поддержка gVisor |
| 🔥 UPX | **28,3 МБ** | `upx` | Уменьшенный размер благодаря UPX |
| 🔥 UPX + gVisor | **29,5 МБ** | `upx-gvisor` | UPX-сжатие и поддержка gVisor |

### Какой вариант выбрать?

- **Standard (`latest`)** — оптимальный выбор для большинства пользователей.
- **gVisor** — если нужна поддержка gVisor, в частности для исходящего Tailscale.
- **UPX** — если важно минимизировать занимаемое место.
- **UPX + gVisor** — если нужны обе возможности одновременно.

> [!NOTE]
> **ARMv5:** UPX-сжатие не применяется, бинарники остаются без сжатия.


## 🐳 Docker Build Variants

| Build | Disk Usage | Docker Tag | Description |
|:---|---:|:---|:---|
| 👀 Standard | **64 MB** | `latest` | Recommended for most users |
| 🌚 gVisor | **73.3 MB** | `gvisor` | gVisor support |
| 🔥 UPX | **28.3 MB** | `upx` | Reduced size with UPX |
| 🔥 UPX + gVisor | **29.5 MB** | `upx-gvisor` | UPX compression with gVisor support |

### Which variant should I choose?

- **Standard (`latest`)** — recommended for most users.
- **gVisor** — if you need gVisor support, especially for outbound Tailscale.
- **UPX** — if minimizing disk usage is important.
- **UPX + gVisor** — if you need both features.

> [!NOTE]
> **ARMv5:** UPX compression is disabled. Binaries remain uncompressed.