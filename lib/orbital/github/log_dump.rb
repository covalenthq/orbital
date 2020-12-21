require 'date'

require 'paint'

module Orbital; end
module Orbital::Github; end

class Orbital::Github::LogDump
  def initialize
    @sections = [{type: :section, events: []}]
    @group_stack = [@sections.first[:events]]
  end

  def pop_group
    return unless @group_stack.length > 1
    @group_stack.pop
  end

  def push_group(desc = nil, desc_timestamp = nil)
    new_group = {type: :group, events: []}
    if desc
      new_group[:description] = {type: :stdout_line, timestamp: desc_timestamp, body: desc}
    end
    @group_stack.last << new_group
    @group_stack << new_group[:events]
  end

  def next_section(desc = nil, desc_timestamp = nil)
    @sections.pop if @sections.last[:events].empty?

    new_section = {type: :section, events: []}
    if desc
      new_section[:description] = {type: :stdout_line, timestamp: desc_timestamp, body: desc}
    end
    @sections << new_section
    @group_stack = [new_section[:events]]
  end

  def emit_stdout_line(line, timestamp)
    @group_stack.last << {type: :stdout_line, timestamp: timestamp, body: line}
  end

  def emit_stderr_line(line, timestamp)
    @group_stack.last << {type: :stderr_line, timestamp: timestamp, body: line}
  end

  def emit_command(cmd, timestamp)
    @group_stack.last << {type: :command, timestamp: timestamp, body: cmd}
  end

  def self.parse(logs_str)
    dump = self.new

    logs_str.split("\n").each do |ln|
      timestamp, ln = take_timestamp(ln)
      op, text = take_op(ln)
      text = text.strip
      text = nil if text.empty?

      case op
      when :group
        dump.push_group(text, timestamp)
      when :endgroup
        dump.pop_group
        raise ArgumentError, "endgroup shouldn't have text" if text
      when :section_begin
        dump.next_section(text, timestamp)
      when :section_end
        dump.next_section
      when :command
        dump.emit_command(text, timestamp)
      when :output
        dump.emit_stdout_line(text || '', timestamp)
      when :error
        dump.emit_stderr_line(text || '', timestamp)
      else
        # dump.emit_line(ln, timestamp)
        raise ArgumentError, "unknown log op #{op}"
      end
    end

    dump.fix_groups

    dump
  end

  def self.take_timestamp(ln)
    timestamp = DateTime.parse(ln[0..27]).to_time.utc
    rest = ln[29..-1]
    [timestamp, rest]
  end

  def self.take_op(ln)
    case ln
    when /^##\[section\]Starting: (.+)$/
      [:section_begin, $1]
    when /^##\[section\]Finishing: (.+)$/
      [:section_end, $1]
    when /^##\[(\w+)\](.+)$/
      [$1.intern, $2]
    when /^\[command\](.+)$/
      [:command, $1]
    else
      [:output, ln]
    end
  end

  def fix_groups
    @sections = fix_groups_inner(@sections)
  end

  def fix_groups_inner(events)
    events.map do |ev|
      case ev[:type]
      when :section
        ev[:events] = fix_groups_inner(ev[:events])
        ev
      when :group
        unless ev[:description]
          ev[:description] = ev[:events][0]
          ev[:events] = ev[:events][1..-1]
        end

        ev[:events] = fix_groups_inner(ev[:events])
        ev
      else
        ev
      end
    end
  end

  attr_accessor :sections

  def slice(from_time, to_time)
    copy = self.dup
    copy.sections = slice_inner(@sections, from_time, to_time)
    copy
  end

  def slice_inner(events, from_time, to_time)
    events.flat_map do |ev|
      case ev[:type]
      when :section, :group
        filtered_evs = slice_inner(ev[:events], from_time, to_time)
        if filtered_evs.empty?
          []
        else
          new_ev = ev.dup
          new_ev[:events] = filtered_evs
          [new_ev]
        end
      else
        if ev[:timestamp] >= from_time and ev[:timestamp] <= to_time
          [ev]
        else
          []
        end
      end
    end
  end

  def to_error_report(indent = "")
    lines = to_s_inner(@sections, indent).flatten
    error_slice_end = lines.index(:error_slice_end)
    return "" unless error_slice_end

    error_slice = lines[0 ... error_slice_end]
    if error_slice.length > 10
      error_slice = error_slice[-10 .. -1]
    end

    error_slice.flatten.join("")
  end


  def to_s(indent = "")
    to_s_inner(@sections, indent).flatten.delete(:error_slice_end).join("")
  end

  def to_s_inner(events, indent)
    events.map do |ev|
      case ev[:type]
      when :section
        if events.length == 1
          to_s_inner(ev[:events], indent)
        else
          own_desc = ev[:description] ? to_s_inner([ev[:description]], "").flatten.join("").strip : ""
          ["#{indent}###### #{Paint[own_desc, :bold]}\n", to_s_inner(ev[:events], indent)]
        end
      when :group
        own_desc = Paint[["▼ ", to_s_inner([ev[:description]], "")].flatten.join("").strip, :underline]
        ["#{indent}#{own_desc}\n", to_s_inner(ev[:events], indent + "  ")]
      when :stdout_line
        "#{indent}#{ev[:body]}\n"
      when :stderr_line
        ["#{indent}#{Paint[ev[:body], :red]}\n", :error_slice_end]
      when :command
        "#{indent}#{Paint[ev[:body], :blue]}\n"
      end
    end
  end
end
