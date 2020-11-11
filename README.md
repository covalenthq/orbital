# Kubernetes GitOps

This repo contains a quick-and-dirty implementation of a Kubernetes (k8s)
[GitOps](https://www.weave.works/technologies/gitops/) continuous-deployment
model.

The goal is to eventually transition to [GKE Application Delivery](https://cloud.google.com/kubernetes-engine/docs/concepts/add-on/application-delivery)
when it's ready. It's a near-perfect model for our needs. But the implementation
is not yet fully-baked: deploying it causes k8s cluster breakage, and it has no
open-source release usable to test its logic outside a cloud deployment.

So, for now, we can rely on the scripts in this repo to achieve similar (if
lesser) goals.

## Local Cluster Provisioning Pre-setup (Docker on Mac)

1. Install a recent Ruby, and add its bin dir to your `$PATH`:

   ```shell
   $ brew install ruby
   $ echo 'export PATH=/usr/local/opt/ruby/bin:$PATH' >> ~/.bash_profile
   ```

2. Install the *Google Cloud SDK*, and follow the prompts to log in:

   ```shell
   $ brew cask install google-cloud-sdk
   $ gcloud init
   ```

3. Install `kubectl` from the *Google Cloud SDK*:

   ```shell
   $ gcloud components install kubectl
   ```

4. Install *Docker for Mac*:

   ```shell
   $ brew cask install docker-edge
   ```

5. Add this line to your `/etc/hosts` (workaround for Docker-on-Mac k8s errors):

   ```
   127.0.0.1 localhost.localdomain
   ```

6. Start Docker for Mac.

7. (Optional) In the *Docker for Mac* Preferences, increase VM memory allocation
   — 16GB is recommended.

8. In the *Docker for Mac* Preferences, enable Kubernetes, and wait for it to
   finish initializing.

9. In the *Docker for Mac* tray menu, select the `docker-desktop` Kubernetes
   context. (Or run `kubectl config set-context docker-desktop`; these are
   equivalent.)

10. Enable the local node to pull private Docker images from our
    Google Container Registry bucket:

    ```shell
    $ gcloud iam service-accounts keys create ./cduser-creds.json \
      --iam-account cduser@covalent-project.iam.gserviceaccount.com

    $ kubectl create secret docker-registry covalent-project-gcr-auth \
      --docker-server=gcr.io \
      --docker-username=_json_key \
      --docker-password="$(cat ./cduser-creds.json)" \
      --docker-email=cduser@covalent-project.iam.gserviceaccount.com

    $ kubectl patch serviceaccount default -p \
      '{"imagePullSecrets": [{"name": "covalent-project-gcr-auth"}]}'
    ```

## Usage

Deployment tasks are specified in `Rakefile` format in the `k8s` directory.
For example:

```shell
git clone git@github.com:covalenthq/k8s-infra.git
cd k8s/
rake base
rake infra
```

...will deploy the base infrastructure to your cluster.

All operations are idempotent. Just running `rake` will deploy and/or update
everything, to get you a fully-functional cluster.
