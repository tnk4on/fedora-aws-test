# Fedora AWS Test

Fedora CoreOS VM on Amazon Web Services (EC2) でDev Containerテストを実行するためのスクリプトとGitHub Actionsサンプル。

## 概要

このリポジトリは、AWS EC2上にFedora CoreOSインスタンスを作成し、PodmanとDev Container CLIを使用したテストを実行するためのツールを提供します。

## 構成

- `scripts/setup-fedora-vm.sh`: VM作成とSSH接続確認まで（クリーンな環境）
- `scripts/run-tests-on-vm.sh`: 既存のVMでテストを実行
- `scripts/test-fedora-aws.sh`: 上記2つを順次実行（完全自動化）
- `.github/workflows/test-fedora.yml`: GitHub Actionsでの実行例

## 前提条件

### ローカル実行

1. **AWS CLI**
   ```bash
   # macOS
   brew install awscli
   
   # Linux
   # https://aws.amazon.com/cli/ を参照
   ```

2. **AWS認証**
   
   ローカル実行では、`aws configure` を使用します。
   
   ```bash
   # AWS認証情報を設定
   aws configure
   # AWS Access Key ID: <your-access-key>
   # AWS Secret Access Key: <your-secret-key>
   # Default region name: us-west-2
   # Default output format: json
   ```

3. **必要なIAM権限**
   
   実行するIAMユーザーまたはロールには、以下の権限が必要です：
   - `ec2:RunInstances` - インスタンス作成
   - `ec2:TerminateInstances` - インスタンス削除
   - `ec2:DescribeInstances` - インスタンス情報取得
   - `ec2:DescribeImages` - AMI情報取得
   - `ec2:CreateSecurityGroup` - セキュリティグループ作成
   - `ec2:DeleteSecurityGroup` - セキュリティグループ削除
   - `ec2:AuthorizeSecurityGroupIngress` - セキュリティグループルール追加
   - `ec2:ImportKeyPair` - キーペアインポート
   - `ec2:DeleteKeyPair` - キーペア削除
   
   または、以下のポリシーを付与：
   - `AmazonEC2FullAccess` - EC2完全アクセス（推奨）

4. **AWSリージョンの設定**
   ```bash
   export AWS_REGION=us-west-2
   ```

### GitHub Actions

1. **シークレットの設定**
   - GitHubリポジトリのSettings > Secrets and variables > Actions
   - `AWS_ACCESS_KEY_ID` シークレットを追加
   - `AWS_SECRET_ACCESS_KEY` シークレットを追加

## 使用方法

### 方法1: クリーンな環境で手動テスト（推奨）

VMを作成してSSH接続できる状態までセットアップし、手動でテストを行います：

```bash
# 1. 認証（初回のみ）
aws configure

# 2. 環境変数を設定（オプション）
export AWS_REGION=us-west-2

# 3. VM作成とSSH接続確認
chmod +x scripts/setup-fedora-vm.sh
./scripts/setup-fedora-vm.sh
```

**出力される情報**:
- Instance ID
- VM Name
- VM IP
- SSH Key パス
- SSH接続コマンド

**手動での次のステップ（VM内で実行）**:
```bash
# SSH接続
ssh -i ~/.ssh/ec2_key_<timestamp> core@<VM_IP>

# 1. nvmをインストール
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

# 2. nvmを読み込む（重要！）
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# 3. Node.jsをインストール
nvm install --lts

# 4. @devcontainers/cliをインストール
npm install -g @devcontainers/cli

# 5. テストリポジトリをクローン
git clone https://github.com/tnk4on/podman-devcontainer-test.git

# 6. 手動でテストを実行
cd podman-devcontainer-test/tests/minimal
devcontainer up --workspace-folder . --docker-path podman
```

**インスタンス削除（手動）**:
```bash
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region <AWS_REGION>
```

### 方法2: 自動テスト実行

既存のVMで自動テストを実行：

```bash
# 環境変数を設定（setup-fedora-vm.shの出力から取得）
export VM_NAME=fedora-test-<timestamp>
export VM_IP=<VM_IP>
export SSH_KEY_PATH=~/.ssh/ec2_key_<timestamp>

# テスト実行
chmod +x scripts/run-tests-on-vm.sh
./scripts/run-tests-on-vm.sh
```

### 方法3: 完全自動化（VM作成→テスト→削除）

```bash
chmod +x scripts/test-fedora-aws.sh
./scripts/test-fedora-aws.sh
```

### GitHub Actions

1. リポジトリにプッシュ
2. Actionsタブから `Test (Fedora on AWS)` ワークフローを手動実行
3. または、`main` ブランチへのプッシュで自動実行

## テスト内容

以下のDev Containerテストを実行します：

- ✅ Minimal
- ✅ Dockerfile
- ✅ Features (Go)
- ✅ Docker in Docker
- ✅ Sample Python
- ✅ Sample Node.js
- ✅ Sample Go

## スクリプトの動作

1. **インスタンス作成**: Fedora CoreOS EC2インスタンスを作成
2. **セキュリティグループ作成**: SSHアクセス用のセキュリティグループを作成
3. **キーペアインポート**: SSH鍵をAWSキーペアとしてインポート
4. **SSH接続待機**: インスタンスが起動しSSH接続可能になるまで待機
5. **環境セットアップ**: 
   - Node.js (nvm経由)
   - @devcontainers/cli
   - Podman設定
6. **テスト実行**: 各テストケースを順次実行
7. **リソース削除**: テスト完了後、インスタンス、セキュリティグループ、キーペアを自動削除

## カスタマイズ

### テスト対象リポジトリの変更

`scripts/test-fedora-aws.sh` の以下の行を編集：

```bash
TEST_REPO="https://github.com/tnk4on/podman-devcontainer-test.git"
```

### インスタンス設定の変更

スクリプト内の以下の変数を編集：

```bash
AWS_REGION="us-west-2"
VM_INSTANCE_TYPE="t3.micro"
VM_DISK_SIZE="200"  # GB
```

**インスタンスタイプの変更**:

```bash
export VM_INSTANCE_TYPE="t3.small"  # より多くのメモリとCPU
```

## トラブルシューティング

### AWS CLI インストールエラー

**macOS (Homebrew)**:
```bash
brew install awscli
```

**Linux**:
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### AWS認証エラー

```bash
# 認証情報を確認
aws sts get-caller-identity

# 認証情報を再設定
aws configure
```

### インスタンス作成エラー

**AMIが見つからない場合**:
- Fedora CoreOSのAMI所有者ID（125523088429）が正しいか確認
- リージョンが正しいか確認

**権限エラーの場合**:
- IAMユーザーに `AmazonEC2FullAccess` ポリシーが付与されているか確認

### SSH接続エラー

- VMの起動に時間がかかることがあります（最大2分30秒待機）
- セキュリティグループルールを確認してください
- SSH鍵の権限を確認: `chmod 600 ~/.ssh/ec2_key_*`

### クリーンアップ

VMが削除されなかった場合：

```bash
# インスタンスを終了
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region <AWS_REGION>

# セキュリティグループを削除
aws ec2 delete-security-group --group-id <SECURITY_GROUP_ID> --region <AWS_REGION>

# キーペアを削除
aws ec2 delete-key-pair --key-name <KEY_NAME> --region <AWS_REGION>
```

## ライセンス

MIT

