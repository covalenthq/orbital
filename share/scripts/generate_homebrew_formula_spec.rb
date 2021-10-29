#!/usr/bin/env ruby

require 'digest'
require 'pathname'
require 'open-uri'

sdk_dir = Pathname.new(__FILE__).realpath.expand_path.parent.parent.parent

# find release version
version_module_path = sdk_dir / 'lib' / 'orbital' / 'version.rb'
Kernel.load(version_module_path.to_s)

pkg_version = Orbital::VERSION


# find versions and digests for release dependencies
vendor_cache_dir = sdk_dir / 'vendor' / 'cache'
vendor_cache_dir.mkpath

prev_cached_gems = vendor_cache_dir.children.find_all{ |f| f.file? }
prev_cached_gems.each{ |f| f.unlink }

system("bundle cache", out: '/dev/null', err: '/dev/null')

cached_gems = vendor_cache_dir.children.find_all do |f|
  f.file? and f.basename.to_s =~ /\.gem$/
end

spec_dep_parts = cached_gems.sort.map do |gem_path|
  gem_name_parts = gem_path.basename('.gem').to_s.match(/^(.+?)-([.0-9]+)$/)
  gem_name = gem_name_parts[1]
  gem_version = gem_name_parts[2]
  gem_digest = Digest::SHA256.hexdigest(gem_path.read)

  <<-EOF

  resource "#{gem_name}" do
    url "https://rubygems.org/gems/#{gem_name}-#{gem_version}.gem"
    sha256 "#{gem_digest}"
  end
  EOF
end

release_url = URI.parse("https://github.com/covalenthq/orbital/archive/refs/tags/v#{pkg_version}.zip")
pkg_digest = Digest::SHA256.hexdigest(release_url.open.read)

puts <<-EOF
class Orbital < Formula
  desc "Covalent ops tooling"
  homepage "https://github.com/covalenthq/orbital"
  url "#{release_url}"
  version "#{pkg_version}"
  sha256 "#{pkg_digest}"
  license "MIT"
  revision 1

  uses_from_macos "ruby", since: :catalina

#{spec_dep_parts.join}
  def install
    ENV["GEM_HOME"] = libexec
    ENV["GEM_PATH"] = libexec

    resources.each do |r|
      system "gem", "install", r.cached_download, "--ignore-dependencies",
             "--no-document", "--install-dir", libexec
    end

    system "gem", "build", "orbital.gemspec"
    system "gem", "install", "orbital-\#{version}.gem", "--no-document"

    (bin/"orbital").write_env_script libexec/"bin/orbital",
      PATH:                            "\#{Formula["ruby"].opt_bin}:\#{libexec}/bin:$PATH",
      ORBITAL_INSTALLED_VIA_HOMEBREW:  "true",
      GEM_HOME:                        libexec.to_s,
      GEM_PATH:                        libexec.to_s
  end
end
EOF
