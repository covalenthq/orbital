#!/usr/bin/env ruby

require 'digest'
require 'pathname'
require 'open-uri'

sdk_dir = Pathname.new(__FILE__).realpath.expand_path.parent.parent.parent

# find release version
version_module_path = sdk_dir / 'lib' / 'orbital' / 'version.rb'
Kernel.load(version_module_path.to_s)

pkg_version = Orbital::VERSION

release_url = URI.parse("https://github.com/covalenthq/orbital/archive/refs/tags/v#{pkg_version}.tar.gz")
pkg_digest = Digest::SHA256.hexdigest(release_url.open.read)

puts <<-EOF
class Orbital < Formula
  desc "Covalent ops tooling"
  homepage "https://github.com/covalenthq/orbital"
  url "#{release_url}"
  sha256 "#{pkg_digest}"
  license "MIT"
  revision 1

  depends_on "ruby"

  def install
    ENV["GEM_HOME"] = libexec
    ENV["GEM_PATH"] = libexec

    resources.each do |r|
      system "gem", "install", r.cached_download, "--ignore-dependencies",
             "--no-document", "--install-dir", libexec
    end

    system "gem", "build", "orbital.gemspec"
    system "gem", "install", "orbital-#{pkg_version}.gem", "--no-document"

    env_vars = {
      PATH:                           "\#{Formula["ruby"].opt_bin}:\#{libexec}/bin:$PATH",
      ORBITAL_INSTALLED_VIA_HOMEBREW: "true",
      GEM_HOME:                       libexec.to_s,
      GEM_PATH:                       libexec.to_s,
    }

    (bin/"orbital").write_env_script libexec/"bin/orbital", env_vars
  end

  test do
    :ok
  end
end
EOF
