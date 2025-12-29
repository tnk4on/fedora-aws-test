# Docker-in-Docker on Fedora 43+ with Podman

## 問題の概要

Fedora 43以降の環境で、Podmanをコンテナランタイムとして使用した場合、devcontainerの`docker-in-docker`機能が動作しません。

### エラーメッセージ
```
mount: /sys/kernel/security: permission denied.
Could not mount /sys/kernel/security.
AppArmor detection and --privileged mode might break.
(*) Failed to start docker, retrying...
```

## 根本原因

`/sys/kernel/security`（securityfs）はLinuxカーネルのセキュリティモジュール（AppArmor、SELinuxなど）用の疑似ファイルシステムです。

**制限事項:**
- ユーザー名前空間（user namespace）内からはマウント不可
- `--privileged`オプションでも回避不可能
- これはカーネルレベルのセキュリティ制限

Podman rootlessはユーザー名前空間を使用するため、この制限が適用されます。

## 対応策

### 推奨: Docker Outside of Docker

Podmanソケットを使用してホストのPodmanをコンテナ内から操作する方法です。

#### 設定手順

1. Podmanソケットを有効化:
```bash
systemctl --user enable --now podman.socket
```

2. devcontainer.jsonでdocker-outside-of-docker featureを使用:
```json
{
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "mounts": [
    "source=/run/user/1000/podman/podman.sock,target=/var/run/docker-host.sock,type=bind"
  ]
}
```

3. 手動テスト:
```bash
podman run -it --rm \
  --security-opt label=disable \
  -v /run/user/$(id -u)/podman/podman.sock:/var/run/docker.sock:z \
  docker.io/library/docker:cli \
  docker run --rm hello-world
```

### 代替案1: Rootful Podman（sudo podman）

Rootful Podman（root権限で実行）では、ユーザー名前空間を使用しないため、`/sys/kernel/security`のマウントが可能になる可能性があります。

```bash
# rootful Podmanでdocker:dindを実行
sudo podman run --privileged -it --rm docker.io/library/docker:dind \
  sh -c "dockerd &>/dev/null & sleep 5 && docker run --rm hello-world"
```

**注意**: devcontainer CLIはrootlessモードで動作するため、この方法をdevcontainerで使用するには追加の設定が必要です。

### 代替案2: DockerをホストにインストールDocker

Podmanの代わりにDockerをコンテナランタイムとして使用する場合、docker-in-dockerが正常に動作します。

```bash
# Dockerリポジトリ追加
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

# Dockerインストール
sudo dnf install docker-ce docker-ce-cli containerd.io

# Docker起動
sudo systemctl start docker
sudo systemctl enable docker

# ユーザーをdockerグループに追加
sudo usermod -aG docker $USER
```

Dockerインストール後、devcontainerは自動的にDockerをランタイムとして使用します。

## 検証結果（2024-12-29）

Fedora 43（kernel 6.17.12）+ Podman 5.7.1環境で検証を実施。

| 検証項目 | 結果 | 備考 |
|---------|------|------|
| Podman Rootless + docker-in-docker | ❌ 失敗 | `/sys/kernel/security`マウント拒否 |
| Podman Rootful + docker:dind | ✅ 成功 | `sudo podman run --privileged docker:dind` |
| Podman Rootless + docker-outside-of-docker | ✅ 成功 | Podmanソケット経由 |
| devcontainer + docker-outside-of-docker | ✅ 成功 | 推奨構成 |

### 検証詳細

**Rootful Podmanでのdocker-in-docker成功例：**
```
=== Docker version ===
Client: Version: 29.1.3
Server: Docker Engine - Community Version: 29.1.3

=== Running hello-world ===
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

**devcontainer + docker-outside-of-docker成功例：**
```
devcontainer exec --workspace-folder . docker run --rm hello-world
Hello from Docker!
```

## 機能比較

| 機能 | docker-in-docker | docker-outside-of-docker |
|------|------------------|--------------------------|
| 分離性 | 完全に分離 | ホストと共有 |
| Podman Rootless対応 | ❌ | ✅ |
| Podman Rootful対応 | ✅ | ✅ |
| Docker対応 | ✅ | ✅ |
| パフォーマンス | やや低い | 良好 |
| セキュリティ | 要`--privileged` | ソケットマウントのみ |
| devcontainer統合 | ❌（Podman rootless） | ✅ |

## 検証コマンド

### Docker Outside of Docker（推奨）の動作確認

```bash
# 1. Podmanソケットを有効化
systemctl --user enable --now podman.socket

# 2. ソケットの存在を確認
ls -la /run/user/$(id -u)/podman/podman.sock

# 3. Docker CLIからPodmanを使用してhello-worldを実行
podman run -it --rm \
  --security-opt label=disable \
  -v /run/user/$(id -u)/podman/podman.sock:/var/run/docker.sock:z \
  docker.io/library/docker:cli \
  docker run --rm hello-world
```

### Rootful Podmanでのdocker-in-docker動作確認

```bash
# rootful Podmanでdocker:dindを実行
sudo podman run --privileged -it --rm docker.io/library/docker:dind \
  sh -c "dockerd &>/dev/null & sleep 5 && docker run --rm hello-world"
```

## 結論

Fedora 43+でPodman rootlessを使用する場合、**docker-outside-of-docker**が推奨される対応策です。docker-in-dockerが必要な場合は、以下のいずれかを検討してください：

1. ホストにDockerをインストールしてDockerをランタイムとして使用
2. Rootful Podman（sudo podman）を使用（devcontainerとの統合には追加設定が必要）

## 参考資料

- [devcontainer docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker)
- [devcontainer docker-outside-of-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-outside-of-docker)
- [Podman Socket Activation](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html)

