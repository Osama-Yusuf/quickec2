# quickec2

CLI tool that deploys a fully configured AWS EC2 instance with VPC, networking, IAM, and optional S3 — in one command. Supports both interactive prompts and fully non-interactive flag-based deployment.

No Terraform, no CloudFormation, no YAML. Just answer prompts or pass flags and get a running instance.

## Features

- **Interactive & non-interactive** — guided prompts or one-liner with flags
- **Public & private modes** — public subnet with SSH or private subnet with NAT + SSM-only access
- **OS support** — Amazon Linux 2023, Ubuntu 22.04, Ubuntu 24.04
- **Software installer** — Docker, Git, Node.js, Python, Nginx, Certbot — auto-generates user-data per OS
- **Dry run** — preview every AWS command without creating anything
- **Cost estimate** — see monthly cost breakdown before deploying
- **Config replay** — save config, redeploy identical setups with `--config`
- **One-command cleanup** — tears down everything in the right order
- **State tracking** — all resource IDs saved to `resources.env` for reliable cleanup
- **Auto-tagging** — every resource tagged with project name, `CreatedBy=quickec2`, and timestamp

## Quick Start

```bash
git clone https://github.com/Osama-Yusuf/quickec2.git
cd quickec2

# Interactive — prompts for everything
./quickec2.sh

# Non-interactive — one command, no prompts
./quickec2.sh --profile myprofile --region eu-central-1 --type t3.small --os al2023 --software python --network private -y
```

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- AWS credentials configured (`aws configure`)
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) (for SSM connections)

## Usage

```bash
# Interactive deployment
./quickec2.sh

# Non-interactive — private instance with python, skip confirmation
./quickec2.sh --profile application --region eu-central-1 --type t3.small --os al2023 --software python --network private -y

# Non-interactive — public instance with docker, custom ports
./quickec2.sh --region us-east-1 --type t3.medium --os ubuntu2404 --network public --ports 22,8080 --software docker,nodejs -y

# Preview all commands without creating anything
./quickec2.sh --dry-run

# Deploy from saved config (auto-generated as quickec2.conf after every deploy)
./quickec2.sh --config quickec2.conf

# Check instance status
./quickec2.sh --status

# Connect to instance (auto-detects SSH or SSM)
./quickec2.sh --connect

# Tear down everything
./cleanup.sh
```

## Connecting to Your Instance

```bash
# SSM (private mode — no SSH needed)
aws ssm start-session --target i-0abc123def456 --region eu-central-1
# or just:
./quickec2.sh --connect

# Run a command without a full session
aws ssm send-command \
  --instance-ids i-0abc123def456 \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["whoami && df -h"]}' \
  --region eu-central-1

# SSH (public mode)
ssh -i quickec2-key.pem ec2-user@1.2.3.4
```

## Tips

- **`-y` skips confirmation** — combine with flags for fully unattended deploys, great for scripts and CI
- **Config replay** — after an interactive deploy, `quickec2.conf` is saved automatically. Reuse it with `--config quickec2.conf` to get the same setup again
- **Dry run first** — `--dry-run` with your flags shows the cost estimate and every AWS command that would run, without creating anything
- **SSM > SSH** — private mode with SSM doesn't need open ports, key management, or a public IP. Use it unless you specifically need SSH
- **Run scripts on the instance** — use `aws ssm send-command` to run commands remotely without opening an interactive session
- **Any instance type works** — `--type` accepts any valid EC2 instance type (not just the t3 family in the interactive menu)
- **Cleanup is idempotent** — `./cleanup.sh` reads `resources.env` and deletes everything in the right order. Safe to run multiple times

## CLI Flags

### Deployment Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--name <name>` | Project name | directory name |
| `--region <region>` | AWS region | eu-west-1 |
| `--network <mode>` | `private` or `public` | private |
| `--type <type>` | Instance type | t3.micro |
| `--os <os>` | `al2023`, `ubuntu2204`, `ubuntu2404` | al2023 |
| `--volume-size <gb>` | Root volume size in GB | 20 |
| `--volume-type <type>` | `gp3`, `gp2`, `io1` | gp3 |
| `--software <list>` | Comma-separated: docker,git,nodejs,python,nginx,certbot | docker,git |
| `--ip-type <type>` | `auto` or `elastic` (public only) | auto |
| `--ports <list>` | Inbound ports, comma-separated (public only) | 22,80,443 |
| `--key-pair <opt>` | `create`, `existing`, `none` (public only) | create |
| `--existing-key <name>` | Key pair name (with `--key-pair existing`) | — |
| `--node-version <ver>` | 18, 20, 22 | 20 |
| `--python-version <ver>` | 3.11, 3.12 | 3.12 |
| `--s3` | Create an S3 bucket | no |
| `--s3-bucket <name>` | Bucket name (implies `--s3`) | project-accountid |

### General Flags

| Flag | Description |
|------|-------------|
| `--profile <name>` | Use a named AWS CLI profile |
| `--config <file>` | Load saved config, skip all prompts |
| `--dry-run` | Show config + cost, print AWS commands, exit |
| `--yes`, `-y` | Skip confirmation prompt |
| `--status` | Show instance state, IP, SSM status |
| `--connect` | Auto-detect: SSM (private) or SSH (public) |
| `--help`, `-h` | Show usage |

> **How modes work:** No flags → interactive prompts. Any deployment flag → non-interactive (uses defaults for anything not specified). `--config` → load from file. All three skip prompts for what they already know.

## Interactive Prompts

When no deployment flags are passed, you get guided prompts:

| # | Prompt | Default | Options |
|---|--------|---------|---------|
| 1 | AWS profile | default | any configured profile |
| 2 | Project name | directory name | any |
| 3 | AWS Region | eu-west-1 | any |
| 4 | Network mode | private | public, private |
| 5 | IP type *(public only)* | auto | auto, elastic |
| 6 | Inbound ports *(public only)* | 22,80,443 | comma-separated |
| 7 | Instance type | t3.micro | t3.nano/micro/small/medium/large |
| 8 | Operating system | al2023 | al2023, ubuntu2204, ubuntu2404 |
| 9 | Volume size (GB) | 20 | number |
| 10 | Volume type | gp3 | gp3, gp2, io1 |
| 11 | SSH key pair *(public only)* | create | create, existing, none |
| 12 | Software | docker,git | docker, git, nodejs, python, nginx, certbot |
| 13 | Node.js version *(if selected)* | 20 | 18, 20, 22 |
| 14 | Python version *(if selected)* | 3.12 | 3.11, 3.12 |
| 15 | Create S3 bucket? | no | yes/no |
| 16 | Bucket name *(if yes)* | project-accountid | any |

## Network Modes

### Private (default)
- EC2 in private subnet, NAT Gateway for outbound
- No inbound access, SSM-only connections
- Security group: outbound 80/443 only
- ~$32/mo extra for NAT Gateway

### Public
- EC2 in public subnet with auto or elastic IP
- User-specified inbound ports (default: 22, 80, 443)
- SSH and/or SSM connections
- No NAT Gateway cost

## Cost Estimate

Displayed before deployment confirmation:

```
=== Estimated Monthly Cost ===
  EC2 (t3.micro)                 $7.59
  EBS (20GB gp3)                 $1.60
  NAT Gateway                   $32.40
  ─────────────────────────────────────
  TOTAL (approx)             $41.59/mo
```

## File Structure

```
quickec2/
├── quickec2.sh          # Main entry point
├── cleanup.sh           # Standalone cleanup
└── lib/
    ├── common.sh        # Colors, logging, aws_cmd wrapper, helpers
    ├── prompt.sh        # Interactive prompt functions
    ├── costs.sh         # Cost estimation
    ├── vpc.sh           # VPC, subnets, IGW, NAT, routes
    ├── ec2.sh           # IAM, security group, AMI, key pair, launch
    ├── s3.sh            # S3 bucket creation
    ├── software.sh      # User-data generator per OS
    └── cleanup.sh       # Teardown functions
```

## Generated Files

| File | Purpose | Persists |
|------|---------|----------|
| `resources.env` | All resource IDs for cleanup | Deleted after cleanup |
| `quickec2.conf` | Saved config for replay ([example](#example-config)) | Kept |
| `user-data.sh` | Generated bootstrap script | Deleted after cleanup |
| `*.pem` | SSH key (if created) | Deleted after cleanup |

## Example Config

Auto-generated as `quickec2.conf` after every deploy. Pass it to `--config` to redeploy the same setup:

```bash
AWS_PROFILE="myprofile"
PROJECT_NAME="quickec2"
AWS_REGION="eu-central-1"
NETWORK_MODE="private"
IP_TYPE="auto"
INBOUND_PORTS=""
INSTANCE_TYPE="t3.small"
OS_TYPE="al2023"
VOLUME_SIZE="20"
VOLUME_TYPE="gp3"
KEY_PAIR_OPTION="none"
EXISTING_KEY_NAME=""
SOFTWARE="python"
NODE_VERSION=""
PYTHON_VERSION="3.12"
CREATE_S3=""
S3_BUCKET_NAME=""
```

## License

MIT
