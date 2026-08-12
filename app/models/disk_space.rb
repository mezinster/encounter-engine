# -*- encoding : utf-8 -*-
#
# Free space on the filesystem holding a given path.
#
# Shells out to df rather than adding sys-filesystem: Ruby's stdlib has no
# statvfs, this repository justifies every gem it carries, and df -kP is
# POSIX-specified output. Isolated in its own class so specs can stub the probe
# instead of filling a disk.
#
# This is the ONLY layer that sees the whole disk. The quota and instance-cap
# checks are arithmetic over our own records and are blind to Docker images,
# logs, Postgres growth and the other tenants on this host -- which is why the
# design promotes this from defence-in-depth to mandatory once it became clear
# no separate partition was available.
class DiskSpace
  def self.available_megabytes(path)
    line = df_output(path).lines[1]
    return 0 if line.nil?

    available_kb = line.split[3]
    return 0 if available_kb.nil?

    available_kb.to_i / 1024
  end

  # -P forces POSIX output: one line per filesystem, never wrapped, so the
  # fourth field is reliably "available". -k forces 1024-byte blocks.
  def self.df_output(path)
    `df -kP #{Shellwords.escape(path)} 2>/dev/null`
  rescue StandardError
    ""
  end
end
