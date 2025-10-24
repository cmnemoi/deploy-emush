# Deploy eMush

[![Deploy](https://github.com/cmnemoi/deploy-emush/actions/workflows/deploy.yaml/badge.svg)](https://github.com/cmnemoi/deploy-emush/actions/workflows/deploy.yaml)

An autonomous repository to deploy / self-host [eMush](https://gitlab.com/eternaltwin/mush/mush).

# Prerequisites

- A GNU/Linux server. This installation has been tested on Pop!_OS 22.04 and Ubuntu 25.04.
- [Docker](https://docs.docker.com/get-docker/), Docker Compose and Make installed.
- A domain name pointing to the server, with the following associated subdomains:
  - `emush.yourdomain.com`: the eMush website.
  - `api.emush.yourdomain.com`: the eMush API, used by the website.
  - `eternaltwin.yourdomain.com`: the Eternaltwin website and server, used for user authentication.
  - `jaeger.emush.yourdomain.com`: the Jaeger UI, used to monitor logs and errors.

[How to associate a Namecheap domain name to a server (in french)](https://claude.ai/share/4f787611-6d57-40b6-8624-cf08310f1c0c).

I highly recommend you also add basic security to your server.

The bare minimum would be to **use a non-root user to deploy eMush**, and to install **Fail2Ban** (which may also slightly improve your server's performance) : please refer to this [OVH article (in french)](https://help.ovhcloud.com/csm/fr-vps-security-tips?id=kb_article_view&sysparm_article=KB0047708) for more information.

# Usage

## Manual

```
git clone --recurse-submodules https://github.com/cmnemoi/deploy-emush.git www && cd www
make deploy
```

## Via GitHub Actions (semi-automatic)

- Create a fork of this repository.
- Setup the following secrets in https://github.com/your_username/deploy-emush/settings/secrets/actions
  - `HOST`: The hostname or IP address of your server.
  - `USERNAME`: The SSH username to connect to your server.
  - `SSH_KEY`: The private SSH key to authenticate with your server.
  - `PORT`: The SSH port (usually 22).<
- Go to Actions tab (https://github.com/your_username/deploy-emush/actions/workflows/deploy.yaml) tab and click on "Run workflow".

The [workflow](https://github.com/cmnemoi/deploy-emush/blob/main/.github/workflows/deploy.yaml) of this repository is also programmed to deploy beta updates of eMush every day at 3AM UTC, but you can edit it to your convenance.

## Deployment Channels

eMush supports two deployment channels:

- **Stable** (default): Uses the `master` branch : it's the same version deployed on [Eternaltwin eMush](https://emush.eternaltwin.org).
- **Beta**: Uses the `develop` branch with the latest, non-published, features.

You can switch between channels using the following commands:

```bash
make deploy-beta # or ./deploy.sh --beta
make deploy # or make deploy-stable, ./deploy.sh --stable, ./deploy.sh
```

**Note**: The beta channel may be unstable. Use it at your own risk.

# License

The deployment scripts and infrastructure as code in this repository are licensed under the [Apache License 2.0](LICENCE).

However, eMush is double-licensed under the [AGPL 3.0 or later](https://www.gnu.org/licenses/agpl-3.0.html) and [CC-BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).
Please refer to its [README](https://gitlab.com/eternaltwin/mush/mush#license) for more details.

# Support

Please contact @evian6930 on Discord if you need help.

Otherwise, this repository is provided as-is, and you are responsible for any damage that may arise from its use...
(You've read the licence, right ?)