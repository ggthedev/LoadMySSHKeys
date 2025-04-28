# typed: false
# frozen_string_literal: true

class Sshkeymanager < Formula
  desc "Manages SSH keys, agent, and loads keys for shell sessions"
  homepage "https://github.com/ggthedev/SSHKEYSMANAGER"
  url "https://github.com/ggthedev/SSHKEYSMANAGER/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "e5f9192a754c96f4b4192ccca0b156d3e9770664"
  version "0.0.1"

  head "https://github.com/ggthedev/SSHKEYSMANAGER.git", branch: "main"

  depends_on "coreutils" # Provides 'date' with nanoseconds needed by the script

  def install
    # Install the main script to bin
    bin.install "sshkeymanager.sh"
    # Install the agent setup script to libexec as it's meant to be sourced
    libexec.install "ssh_agent_setup.sh"
  end

  def caveats
    <<~EOS
      The main utility `sshkeymanager.sh` has been installed to:
        #{opt_bin}/sshkeymanager.sh

      To activate the SSH agent setup for your shell sessions, add the following
      line to your shell profile (e.g., ~/.zshrc, ~/.bash_profile, ~/.profile):

        source "#{opt_libexec}/ssh_agent_setup.sh"

      Ensure you remove any previous manual sourcing of the agent script.

      Configuration and logs are typically stored in:
        ~/.config/sshkeymanager/
        ~/Library/Logs/sshkeymanager/ (macOS) or ~/.local/log/sshkeymanager/ (Linux fallback)

      Restart your shell or source your profile for changes to take effect.
    EOS
  end

  test do
    # Test syntax of the sourced script
    system "bash", "-n", libexec/"ssh_agent_setup.sh"

    # Test presence and basic execution of the main script
    assert_predicate bin/"sshkeymanager.sh", :exist?
    assert_predicate bin/"sshkeymanager.sh", :executable?
    # Check if running with --help works (replace with a more meaningful basic command if needed)
    shell_output("#{bin}/sshkeymanager.sh --help")
  end
end 