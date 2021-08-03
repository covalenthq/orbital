# Orbital

Orbital is a tool for the release management and deployment of applications and infrastructure components in a Kubernetes cluster.

## Runtime environment setup (macOS)

1. Install a recent Ruby, and add its bin dir to your `$PATH`. Also install
the `bundler` gem.

```sh
brew install ruby
echo 'export PATH=/usr/local/opt/ruby/bin:$PATH' >> ~/.bash_profile
gem install bundler
```

2. Install the *Google Cloud SDK*, and follow the prompts to log in:

```sh
brew cask install google-cloud-sdk
gcloud init
```

3. In the root of this repo, install the Rubygem dependencies:

```sh
git clone git@github.com:covalenthq/k8s-infra.git
cd k8s-infra/
bundle install
```

## K8s development cluster provisioning (Docker for Mac)

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

## Usage

Scripted tasks are specified in `Rakefile` format.

You can see the list of implemented top-level tasks by running:

```sh
rake --tasks
```

Tasks form a dependency-graph and are idempotent. Don't worry about the side-effects of a task; just identify the set of capabilities you want to set up on your host and in your cluster, run the relevant tasks, and everything should "just work."

To set up the *minimum viable* set of infrastructure components required to deploy Covalent applications into a given k8s cluster, run:

```sh
rake cluster:base
```
