# frozen_string_literal: true

require 'paint'

require 'orbital/command'
require 'orbital/secret_manager/managed_secret/part'

module Orbital; end
module Orbital::Commands; end
module Orbital::Commands::Secrets; end

class Orbital::SecretsCommand < Orbital::Command
  def validate_environment!
    return if @context_validated

    @context.validate :has_project do
      @context.project!
    end

    @context.validate :has_appctlconfig do
      @context.application!
    end

    @context_validated = true
  end

  def ensure_sealer!
    @context.application.select_deploy_environment(@options.env)
    active_de_loc = @context.deploy_environment.location

    k8s_namespaces_with_matching_location =
      @context.application.deploy_environments.values
      .find_all{ |de| de.location == active_de_loc }
      .map{ |de| de.k8s_namespace }

    @context.project.secret_manager.sealing_for_namespaces(k8s_namespaces_with_matching_location)
  end
end

class Orbital::Commands::Secrets::List < Orbital::SecretsCommand
  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    secs =
      @context.project.secret_manager.secrets
      .values.sort_by{ |sec| sec.name }

    secs_table =
      table(header: ["Secret", "Type", "Keys", "🔒"])

    secs.each do |sec|
      sec_parts = sec.parts.values
      any_sealed = sec_parts.any?(&:sealed?)
      all_sealed = sec_parts.all?(&:sealed?)
      seal_icon = all_sealed ? Paint['✓', :green] : (any_sealed ? Paint["∃", :yellow] : " ")

      secs_table << [Paint[sec.name, :bright], sec.type.to_s, sec_parts.length.to_s, seal_icon]
    end

    puts secs_table.render(:unicode, alignments: [:left, :center, :right, :right], padding: [0, 1, 0, 1])
  end
end

class Orbital::Commands::Secrets::Describe < Orbital::SecretsCommand
  PREVIEW_DUMMY_SYMBOL = Orbital::SecretManager::ManagedSecret::Part::PREVIEW_DUMMY_SYMBOL
  NONURLSAFE_PATTERN = Regexp.new("[^-_A-Za-z0-9.~:\\/?#\\[\\]@!$&'()*+,;%=#{PREVIEW_DUMMY_SYMBOL}]")
  DUMMIED_PATTERN = Regexp.new("#{PREVIEW_DUMMY_SYMBOL}+")
  NONPRINTABLE_PATTERN = /[^[:print:][:space:]]/

  RUBY_STR_ESCAPES_PATTERN = /
  (\\x[a-fA-F0-9]{2}) |
  (\\u[a-fA-F0-9]{4}) |
  (\\u\{[a-fA-F0-9]+\}) |
  (\\.)
  /x

  def self.highlight_masked_parts(str)
    str.gsub(DUMMIED_PATTERN) do |masked_part|
      Paint[masked_part, :blue]
    end
  end

  def self.fancy_inspect(str, colorize: true, limit: nil)
    ansi =
      limit ? str[0, limit] : str

    was_elided = ansi.bytesize < str.bytesize

    if colorize
      ansi = ansi.inspect.gsub(RUBY_STR_ESCAPES_PATTERN) do |esc|
        Paint[esc, :bright, :magenta] + Paint.color(:red)
      end
    end

    if was_elided
      if colorize
        ansi = ansi[0..-2] + Paint["…", :white] + Paint.color(:red) + '"'
      else
        ansi = ansi[0..-2] + '…"'
      end
    end

    if colorize
      Paint[ansi, :red]
    else
      ansi
    end
  end

  def self.fancy_hexinspect(binstr, colorize: true, limit: nil)
    head_part = colorize ? Paint["0x", :white] : "0x"

    body_part =
      if limit
        binstr.unpack("H#{limit}").first
      else
        binstr.unpack("H*").first
      end

    was_elided = (body_part.bytesize / 2) < binstr.bytesize

    if colorize
      body_part = Paint[body_part, :green]
    end

    elision_part =
      if was_elided
        colorize ? Paint["…", :white] : "…"
      else
        ""
      end

    head_part + body_part + elision_part
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    sec = @context.project.secret_manager.secrets[@options.name]

    unless sec
      logger.fatal ["no secret '", @options.name, "' exists in the managed-secrets store"]
    end

    puts("Secret " + Paint[sec.name, :bright])

    fields_table = table()
    fields_table << ["Type:", sec.type.to_s]
    fields_table << ["Keys:", ""]

    puts fields_table.render(
      :basic,
      alignments: [:right, :left],
      indent: 2
    )

    parts_table =
      table(header: ["Key", "Rev", "Type", "🔒", "Value Preview"])

    sec.parts.values.sort_by{ |part| part.key }.each do |part|
      seal_icon = part.sealed? ? Paint['✓', :green] : " "

      value_preview_part =
        case part.printable_value
        in [:special, value_desc]
          Paint[value_desc, :white]
        in [:abstract, value_desc]
          Paint["(#{value_desc})", :white]
        in [:literal, ""]
          Paint['""', :white]
        in [:literal, value_desc]
          case [value_desc.length > 200, NONPRINTABLE_PATTERN.match?(value_desc), NONURLSAFE_PATTERN.match?(value_desc)]
          in [false, false, false]
            self.class.highlight_masked_parts(value_desc)
          in [false, false, true]
            self.class.fancy_inspect(value_desc)
          in [false, true, _]
            self.class.fancy_hexinspect(value_desc)
          in [true, false, false]
            value_desc[0...200] + Paint["…", :white]
          in [true, false, true]
            self.class.fancy_inspect(value_desc, limit: 80)
          in [true, true, _]
            self.class.fancy_hexinspect(value_desc, limit: 32)
          end
        end

      parts_table << [
        Paint[part.key, :bright],
        part.value_revision.to_s,
        part.type.to_s,
        seal_icon,
        value_preview_part
      ]
    end

    puts parts_table.render(
      :unicode,
      alignments: [:left, :right, :center, :right, :left],
      indent: 2,
      padding: [0, 1, 0, 1]
    )
  end
end

class Orbital::Commands::Secrets::Set < Orbital::SecretsCommand
  def execute(input: $stdin, output: $stdout)
    self.validate_environment!
    self.ensure_sealer! if @options.seal

    value_to_set =
      if @options.value
        @options.value
      elsif $stdin.tty?
        prompt.mask("New value for key: ")
      else
        $stdin.read
      end

    value_type =
      if @options.type and @options.type.length > 0
        @options.type
      else
        'Opaque'
      end

    mask_fields =
      if @options.mask_fields and @options.mask_fields.length > 0
        @options.mask_fields.split(',').map(&:intern)
      else
        nil
      end

    @context.project.secret_manager.with_secret(@options.name, create: true) do |sec|
      sec.define(
        @options.key,
        value_to_set,
        type: value_type,
        mask_fields: mask_fields,
        seal: @options.seal
      )
    end

    @context.project.secret_manager.persist_all!
  end
end

class Orbital::Commands::Secrets::Delete < Orbital::SecretsCommand
  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    return unless @context.project.secret_manager.secrets.has_key?(@options.name)

    @context.project.secret_manager.with_secret(@options.name) do |sec|
      sec.delete!
    end

    @context.project.secret_manager.persist_all!
  end
end

class Orbital::Commands::Secrets::MarkCompromised < Orbital::SecretsCommand
  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    logger.fatal 'not implemented'
  end
end

class Orbital::Commands::Secrets::Seal < Orbital::SecretsCommand
  def execute(input: $stdin, output: $stdout)
    self.validate_environment!
    self.ensure_sealer!

    @context.project.secret_manager.with_secret(@options.name) do |sec|
      target_parts =
        if @options.key
          unless part = sec.parts[@options.key]
            logger.fatal ["unknown key ", @options.key, " for secret ", @options.name]
          end
          [part]
        else
          sec.parts.values
        end

      target_parts.each do |part|
        if part.sealed? and @options.reseal
          part.reseal!
        else
          part.seal!
        end
      end
    end

    @context.project.secret_manager.persist_all!
  end
end


class Orbital::Commands::Secrets::Unseal < Orbital::SecretsCommand
  def execute(input: $stdin, output: $stdout)
    self.validate_environment!
    self.ensure_sealer!

    @context.project.secret_manager.with_secret(@options.name) do |sec|
      target_parts =
        if @options.key
          unless part = sec.parts[@options.key]
            logger.fatal ["unknown key ", @options.key, " for secret ", @options.name]
          end
          [part]
        else
          sec.parts.values
        end

      target_parts.each(&:unseal!)
    end

    @context.project.secret_manager.persist_all!
  end
end
