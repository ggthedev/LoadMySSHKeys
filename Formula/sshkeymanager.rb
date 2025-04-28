# typed: false
# frozen_string_literal: true

class Sshkeymanager < Formula
  desc "SSH key management tool with a menu driven interface as well as a CLI interface"
  homepage "https://github.com/ggthedev/SSHKEYSMANAGER"
  url "https://github.com/ggthedev/SSHKEYSMANAGER/archive/refs/tags/v0.0.1.2.tar.gz"
  sha256 "0c6c1178b564812d8bdcb0c05052c25903a6f3f7a2296105fcc738127778d7fb"
  license "BSD-3-Clause"
  head "https://github.com/ggthedev/SSHKEYSMANAGER.git", branch: "main"

  depends_on "bash"
  depends_on "coreutils" # Provides 'date' with nanoseconds needed by the script
  # Make gnu-getopt optional on macOS
  depends_on "gnu-getopt" => :optional if OS.mac?

  def install
    # Install library and main script into libexec
    libexec.install "lib"
    libexec.install "sshkeymanager.sh"

    # Create a wrapper script using /usr/bin/env bash
    (bin/"sshkeymanager").write <<~EOS
      #!/usr/bin/env bash
      # Execute the main script from libexec, relying on PATH for bash
      exec "#{libexec}/sshkeymanager.sh" "$@"
    EOS

    # Keep gnu-getopt replacement logic if needed
    if OS.mac? && build.with?("gnu-getopt")
      inreplace libexec/"sshkeymanager.sh" do |s|
        s.gsub! "/usr/local/opt/gnu-getopt/bin/getopt", Formula["gnu-getopt"].opt_bin/"getopt"
        s.gsub! "/opt/homebrew/opt/gnu-getopt/bin/getopt", Formula["gnu-getopt"].opt_bin/"getopt"
      end
    end
  end

  def caveats
    s = <<~EOS
      The main utility `sshkeymanager` has been installed.

      **Compatibility Note:** This script works best with Bash version 4.0 or higher.
      While it includes fallbacks for older Bash versions (like macOS default Bash 3.x),
      using Bash 4.0+ is recommended for optimal performance and features.

      You can install a newer Bash via Homebrew if needed:
        `brew install bash`
      Then ensure the `bash` command in your PATH points to the newer version,
      or explicitly run the script with the Homebrew Bash path.

      Configuration and logs are typically stored in:
        ~/.config/sshkeymanager/
        ~/Library/Logs/sshkeymanager/ (macOS) or ~/.local/log/sshkeymanager/ (Linux fallback)
    EOS
    # Add gnu-getopt recommendation caveat if macOS
    if OS.mac?
      s += <<~EOS

        On macOS, installing with gnu-getopt is recommended for full CLI compatibility:
          brew reinstall sshkeymanager --with-gnu-getopt
      EOS
    end
    s
  end

  test do
    # Basic test remains the same
    assert_match "Usage: sshkeymanager", shell_output("#{bin}/sshkeymanager --help")
  end
end 