# Orbital

Orbital is a tool for the release management and deployment of applications and infrastructure components within a Kubernetes cluster. 

Orbital was built to mimic the format and deploy process of Google Kubernetes Engine's proprietary [Application Delivery](https://cloud.google.com/kubernetes-engine/docs/concepts/add-on/application-delivery) infrastructure. Orbital-managed apps and components are "source compatible" with Application Delivery; repos created for use with Application Delivery's `appctl(1)` can easily be migrated to Orbital.

Orbital was created because we at Covalent really like GKE's Application Delivery, but didn't like that it was proprietary, non-robust, and dog-slow to run deploys with. Orbital is none of those things.

For now, Orbital is still architected mostly for deployments to Google Kubernetes Engine specifically; but it is being actively rearchitected with a focus on use in an arbitrary Kubernetes cluster.

## Setup

### Runtime environment setup (macOS)

1. Install a recent Ruby, and add its bin dir to your `$PATH`. Also install
the `bundler` gem.

```sh
brew install ruby
echo 'export PATH=/usr/local/opt/ruby/bin:$PATH' >> ~/.bash_profile
gem install bundler
```

2. Install the *Google Cloud SDK*, and follow the prompts to log in:

```sh
brew install --cask google-cloud-sdk
gcloud init
```

3. Either:

* install the `orbital` gem (provides `orbital` command)
* clone this repository (use `./exe/orbital`)

### K8s development cluster provisioning (Docker for Mac)

1. Install *Docker for Mac*, and `kubectl`:

```sh
brew install kubectl
brew cask install docker-edge
```

2. Start *Docker for Mac*.

3. (Optional) In the *Docker for Mac* Preferences, increase VM memory allocation
   — 16GB is recommended.

4. In the *Docker for Mac* Preferences, enable Kubernetes, and wait for it to
   finish initializing.

5. In the *Docker for Mac* tray menu, select the `docker-desktop` Kubernetes
   context. (Or run `kubectl config set-context docker-desktop`; these are
   equivalent.)

## App repo configuration

For the most part, you can follow the instructions in GKE's [Application Delivery](https://cloud.google.com/kubernetes-engine/docs/concepts/add-on/application-delivery) tutorial for setting up a repo. Orbital reads and uses the `.appctlconfig` file placed at the root of the repo to discover the configured locations for other resources, exactly as `appctl(1)` does. Orbital bakes down Kustomize manifests found in `$CONFIG_DIR/*/Kustomization.yaml` just as `appctl(1)` does; and also relies on the same format for `$DELIVERY_DIR/envs/*.yaml` files.

The only major difference is the addition of another required file `.orbital/project.yaml`, with contents similar to the following:

```yaml
---
schema_version: 1

default_environment: staging

artifacts:
  "django":
    build_steps:
      - type: docker_image
        spec_type: Dockerfile
        image_name: gcr.io/covalent-project/django
        source_path: "."
```

The `.orbital/project.yaml` file configures things that `appctl(1)` doesn't know or care about: project-wide defaults, and artifact build-steps. For most applications, the above (with tweaks for your own build-step name and Docker tag) will work just fine.

#### Directory Configuration

If creating a greenfield *application* project with Orbital — where the application will have many root-level directories in the repo — the following less-obtrusive `.appctlconfig` directory configuration is suggested, lining up with Orbital's choice of `.orbital`:

```yaml
config_path: .appctl/config
delivery_path: .appctl/delivery
deploy_repo_path: .appctl/deployment
```

Alternately, if creating a greenfield *infrastructure component* project with Orbital — where the component will effectively exist _only_ in the form of a bunch of Kustomize manifests — it is suggested to instead make the appctl directory visible:

```yaml
config_path: appctl/config
delivery_path: appctl/delivery
deploy_repo_path: appctl/deployment
```

...and, as well, to name Orbital's configuration directory `orbital` rather than `.orbital`. (No config needed; Orbital checks both locations.)

## Usage

Orbital is _somewhat_ self-documenting. You can get a list of subcommands by running `orbital help`.

### Set up and Manage your Workstation

`orbital setup` is an umbrella for setup tasks used to bootstrap and maintain configuration for both local workstations and k8s clusters.

(N.B. This area of Orbital is currently under re-development, and should not currently be relied upon.)

### Make Releases, Deploy Releases

1. `orbital release` will create a release from the current commit.

2. `orbital deploy -t [release-tag] -e [deploy-environment]` will deploy a tagged release to a configured k8s target environment.

These subcommands work the same as the equivalent subcommands of `appctl(1)`.

`orbital release -d` will create a release, and—if successful—will automatically deploy said release to the default target-env (assumed to be `"staging"` unless overridden.)

### Manage Sealed Secrets

Orbital embeds a work-alike implementation of Bitnami's [`kubeseal(1)`](https://github.com/bitnami-labs/sealed-secrets) client for creating and managing sealed secrets. These secrets exist as files within an Orbital application's repo, under the `.orbital/managed-secrets` directory.

N.B. This component just modifies files in your repo's worktree. After calling `orbital secrets` subcommands, you should review and commit the resulting changes to your repo.

Notable differences from using `kubeseal(1)`:

* `kubeseal(1)`'s `SealedSecret` k8s resource format does not interact well with Kustomize, as Kustomize attempts to auto-suffix Secrets and references to them with a fingerprint hash, to forcibly "touch" any resource referencing a Secret when that Secret is updated. Because of this, Orbital does not store its managed sealed secrets in `kubeseal(1)`'s SealedSecret format, but rather has its own YAML-based format, from which `SealedSecret` resources are generated by a Kustomize plugin.

*  Orbital's secrets manager implements *local unsealing* of previously-sealed secrets, provided your k8s ServiceAccount has `GET` access to the cluster-sealer's signing-certificate secret. (Only k8s cluster administrators should be granted this privilege.) Of course, this refutes the whole "one-way encrypted" property Bitnami insists is true; but clearly, since this is possible, that was never the case.

Available subcommands:

* Use `orbital secrets` or `orbital secrets list` to list the sealed secrets under Orbital's management. (You can also just examine the `.orbital/managed-secrets` dir, where each sealed secret is backed by a YAML file.)

* Use `orbital secrets describe -n <secret-name>` to view a specific secret. If the secret is sealed, pass `-u` or `--unsealed` to attempt to unseal the secret in-memory for display.

* Use `orbital secrets seal -n <secret-name>` to seal a secret. Add `-k <part-name>` to only seal a specific part of the secret.

* Use `orbital secrets unseal -n <secret-name>` to attempt to unseal a secret. Add `-k <part-name>` to only attempt to unseal a specific part of the secret.

* Use `orbital secrets set -n <secret-name> -k <part-name> -t <part-type> -v <value>` to add/update an unsealed part in a secret.

* Use `orbital secrets set -n <secret-name> -k <part-name> -t <part-type> --seal` to add/update an sealed part in a secret. (The secret will be taken from stdin, or prompted for if the terminal is interactive.)
