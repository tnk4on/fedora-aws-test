# GitHub Actions Ubuntu vs Fedora 43: docker-in-docker 動作差異

## 概要

GitHub Actions UbuntuではPodmanでdocker-in-dockerテストが成功するが、Fedora 43では失敗する。

## 環境比較

| 項目 | GitHub Actions Ubuntu | Fedora 43 (AWS EC2) |
|------|----------------------|---------------------|
| **OS** | Ubuntu 24.04 (ubuntu-latest) | Fedora 43 Cloud Base |
| **カーネル** | 6.8.x (Ubuntu kernel) | 6.17.12-300.fc43.x86_64 |
| **Podman** | apt版 (4.x) | dnf版 (5.7.1) |
| **cgroup** | cgroup v2 | cgroup v2 |
| **SELinux** | なし (AppArmor) | あり（無効化設定） |
| **ユーザー名前空間** | 有効 | 有効 |

## docker-in-docker テスト結果

| 環境 | 結果 | 詳細 |
|------|------|------|
| GitHub Actions Ubuntu + Podman | ✅ 成功 | `docker run hello-world` 動作 |
| Fedora 43 + Podman rootless | ❌ 失敗 | `/sys/kernel/security` マウント拒否 |
| Fedora 43 + Podman rootful | ✅ 成功 | `sudo podman` で動作 |

## 根本原因

### 失敗するエラーメッセージ（Fedora 43）

```
mount: /sys/kernel/security: permission denied.
Could not mount /sys/kernel/security.
AppArmor detection and --privileged mode might break.
(*) Failed to start docker, retrying...
```

### なぜUbuntuでは成功するか

| 要因 | Ubuntu | Fedora 43 |
|------|--------|-----------|
| **カーネルバージョン** | 6.8.x | 6.17.x（最新） |
| **securityfs制限** | 緩い | 厳しい |
| **ユーザー名前空間でのマウント** | 一部許可 | より制限的 |
| **カーネルセキュリティ機能** | 安定版 | 最新の強化版 |

### 技術的詳細

1. **Fedora 43のカーネル（6.17）の新しいセキュリティ制限**
   - ユーザー名前空間内での`/sys/kernel/security`（securityfs）マウントが拒否される
   - これはAppArmor/SELinux検出のために必要
   - `--privileged`オプションでも回避不可

2. **Ubuntuのカーネル（6.8）では**
   - securityfsのマウント制限がより緩い
   - ユーザー名前空間内でも一部のマウントが許可される

3. **Podmanバージョンの違い**
   - Ubuntu: Podman 4.x（aptリポジトリ）
   - Fedora 43: Podman 5.7.1（最新）
   - 両方ともrootlessで動作するが、カーネルの制限が異なる

## ワークフローの違い

### Ubuntu (test-ubuntu.yml)

```yaml
- name: Test - Docker in Docker
  run: |
    cd tests/docker-in-docker
    OUTPUT=$(devcontainer up --workspace-folder . --docker-path podman 2>&1)
    podman exec "$CONTAINER_ID" docker run --rm hello-world
    echo "✅ Docker in Docker PASSED"
```

### Fedora (test-fedora.yml)

```yaml
# スキップ
- name: Test - Docker in Docker (Skipped)
  run: |
    echo "⏭️ Docker in Docker test skipped"
    echo "Reason: docker-in-docker feature requires /sys/kernel/security mount"
    echo "Alternative: Use docker-outside-of-docker feature with Podman socket"
```

## 対応策

### Fedora 43での代替手段

| 方法 | 動作 | 推奨 |
|------|------|------|
| **docker-outside-of-docker** | ✅ | ⭐⭐⭐ |
| **Rootful Podman** | ✅ | ⭐⭐ |
| **Dockerをインストール** | ✅ | ⭐⭐ |
| **Podman Rootless + docker-in-docker** | ❌ | - |

### docker-outside-of-docker の設定

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

## 結論

| 環境 | docker-in-docker | 推奨対応 |
|------|------------------|---------|
| **Ubuntu (GitHub Actions)** | ✅ 動作 | そのまま使用可能 |
| **Fedora 43** | ❌ 非動作 | docker-outside-of-docker を使用 |

Fedora 43の最新カーネル（6.17）では、セキュリティ強化のためユーザー名前空間内での`/sys/kernel/security`マウントが制限されている。これはカーネルレベルの変更であり、Podmanの設定では回避できない。

## 関連資料

- [Docker-in-Docker詳細ドキュメント](./DOCKER_IN_DOCKER.md)
- [devcontainer docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker)
- [devcontainer docker-outside-of-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-outside-of-docker)

