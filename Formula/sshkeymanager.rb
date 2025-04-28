# typed: false
# frozen_string_literal: true

class Sshkeymanager < Formula
  desc "Manages SSH keys, agent, and loads keys for shell sessions"
  homepage "https://github.com/ggthedev/SSHKEYSMANAGER"
  url "https://github.com/ggthedev/SSHKEYSMANAGER/archive/refs/tags/v0.0.1.2.tar.gz"
  sha256 "0c6c1178b564812d8bdcb0c05052c25903a6f3f7a2296105fcc738127778d7fb"
  version "0.0.1.2"
  
  head "https://github.com/ggthedev/SSHKEYSMANAGER.git", branch: "main"

  depends_on "coreutils" # Provides 'date' with nanoseconds needed by the script
  # Make gnu-getopt optional on macOS
  depends_on "gnu-getopt" => :optional if OS.mac?

  def install
    # Install the main script and the lib directory into libexec
    libexec.install "sshkeymanager.sh"
    libexec.install "lib"

    # Create a wrapper script in bin that calls the main script in libexec
    (bin/"sshkeymanager").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/sshkeymanager.sh" "$@"
    EOS

    # Use inreplace only if macOS AND the optional gnu-getopt was built
    if OS.mac? && build.with?("gnu-getopt")
      # Replace the simple `getopt` check/call path in the *libexec* script
      inreplace libexec/"sshkeymanager.sh" do |s|
        # Adjust path finding logic if needed, assuming script uses _check_gnu_getopt
        # This might need refinement depending on how the script finds getopt
        s.gsub! "/usr/local/opt/gnu-getopt/bin/getopt", Formula["gnu-getopt"].opt_bin/"getopt"
        s.gsub! "/opt/homebrew/opt/gnu-getopt/bin/getopt", Formula["gnu-getopt"].opt_bin/"getopt"
        # If script relies on `command -v getopt` returning gnu-getopt first,
        # ensure PATH is set appropriately or consider direct replacement if simpler.
      end
    end
  end

  def caveats
    <<~EOS
      The main utility `sshkeymanager` has been installed and can be run directly.

      Configuration and logs are typically stored in:
        ~/.config/sshkeymanager/
        ~/Library/Logs/sshkeymanager/ (macOS) or ~/.local/log/sshkeymanager/ (Linux fallback)

      If you previously sourced `ssh_agent_setup.sh`, please remove that line
      from your shell profile (e.g., ~/.zshrc, ~/.bash_profile).
    EOS
    # Keep the gnu-getopt recommendation caveat as it's still relevant
    s = ""
    if OS.mac?
      s += <<~EOS

        On macOS, it is recommended to install with gnu-getopt for full compatibility
        with command-line options:
          brew reinstall sshkeymanager --with-gnu-getopt
      EOS
    end
    s # Return the combined caveats string
  end

  test do
    # Test the wrapper script in bin
    assert_predicate bin/"sshkeymanager", :exist?
    assert_predicate bin/"sshkeymanager", :executable?

    # Test the main script in libexec directly for syntax
    assert_predicate libexec/"sshkeymanager.sh", :exist?
    system "bash", "-n", libexec/"sshkeymanager.sh"
    # Test lib files syntax too
    Dir[libexec/"lib/*.sh"].each do |lib_file|
      system "bash", "-n", lib_file
    end

    # Check if running the wrapper with --help works
    shell_output("#{bin}/sshkeymanager --help")
  end
end 