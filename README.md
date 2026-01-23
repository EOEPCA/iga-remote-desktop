# Remote desktop

This interactive application provides a remote desktop via JupyterHub.

It relies on the [jupyter-remote-desktop-proxy](https://github.com/jupyterhub/jupyter-remote-desktop-proxy)

## ApplicationHub Configuration

Below an example of configuration in the ApplicationHub:

```yaml
- id: profile_iga_remote_desktop
  groups: 
  - group-1
  definition:
    display_name: Remote Desktop
    slug: iga_remote_desktop
    default: False
    kubespawner_override:
      cpu_limit: 1
      mem_limit: 4G
      image:  eoepca/iga-remote-desktop
  default_url: "desktop"
  node_selector: 
    k8s.provider.com/pool-name: node-pool-a
```

## Container Image Strategy & Availability

This project publishes container images to GitHub Container Registry (GHCR) following a clear and deterministic tagging strategy aligned with the Git branching and release model.

### Image Registry

Images are published to:

```
ghcr.io/<repository-owner>/iga-remote-desktop
```

The registry owner corresponds to the GitHub repository owner (user or organization).

Images are built using Kaniko and pushed using OCI-compliant tooling.

### Tagging Strategy

The image tag is derived automatically from the Git reference that triggered the build:


| Git reference    | Image tag    | Purpose                            |
| ---------------- | ------------ | ---------------------------------- |
| `develop` branch | `latest-dev` | Development and integration builds |
| `main` branch    | `latest`     | Stable branch builds               |
| Git tag `vX.Y.Z` | `X.Y.Z`      | Immutable release builds           |