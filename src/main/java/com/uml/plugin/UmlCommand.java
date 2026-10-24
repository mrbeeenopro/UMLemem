package com.uml.plugin;

import com.uml.server.UmlManager;
import com.uml.server.UmlManager.PortMapping;
import org.bukkit.ChatColor;
import org.bukkit.command.Command;
import org.bukkit.command.CommandExecutor;
import org.bukkit.command.CommandSender;
import org.bukkit.command.TabCompleter;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class UmlCommand implements CommandExecutor, TabCompleter {

    private final UmlPlugin plugin;

    public UmlCommand(UmlPlugin plugin) {
        this.plugin = plugin;
    }

    @Override
    public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        if (!sender.hasPermission("uml.admin")) {
            sender.sendMessage(ChatColor.RED + "Unknown command. Type \"/help\" for help.");
            return true;
        }

        if (args.length == 0) {
            sendHelp(sender);
            return true;
        }

        String sub = args[0].toLowerCase();
        UmlManager manager = UmlManager.getInstance();

        switch (sub) {
            case "status": {
                if (!manager.isRunning()) {
                    sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "System is currently STOPPED.");
                } else {
                    long uptime = manager.getUptimeSeconds();
                    long h = uptime / 3600;
                    long m = (uptime % 3600) / 60;
                    long s = uptime % 60;
                    sender.sendMessage(ChatColor.GOLD + "=== [UML AC Status] ===");
                    sender.sendMessage(ChatColor.YELLOW + "  State: " + ChatColor.GREEN + "RUNNING");
                    sender.sendMessage(ChatColor.YELLOW + "  Port Forwards (Multi-Port):");
                    for (PortMapping pm : manager.getPortMappings()) {
                        String badge = pm.isActive() ? ChatColor.GREEN + "[ACTIVE]" : ChatColor.YELLOW + "[FORWARDING]";
                        sender.sendMessage(ChatColor.WHITE + "    • " + pm.getHostPort() + " (host) -> " + pm.getGuestPort() + " (guest/" + pm.getProto() + ") " + badge);
                    }
                    sender.sendMessage(ChatColor.YELLOW + "  vCPUs: " + ChatColor.WHITE + manager.getCpus());
                    sender.sendMessage(ChatColor.YELLOW + "  RAM: " + ChatColor.WHITE + manager.getMemory());
                    sender.sendMessage(ChatColor.YELLOW + "  Disk: " + ChatColor.WHITE + manager.getDiskSize());
                    sender.sendMessage(ChatColor.YELLOW + "  Uptime: " + ChatColor.WHITE + String.format("%02dh %02dm %02ds", h, m, s));
                    sender.sendMessage(ChatColor.AQUA + "  SSH: " + ChatColor.WHITE + "ssh -X -p " + manager.getPrimaryHostPort() + " root@<SERVER_IP>");
                    sender.sendMessage(ChatColor.GRAY + "  Root Password: 12345678");
                }
                return true;
            }

            case "logs": {
                int lines = 20;
                if (args.length > 1) {
                    try { lines = Integer.parseInt(args[1]); } catch (Exception ignored) {}
                }
                List<String> logs = manager.getRecentLogs();
                sender.sendMessage(ChatColor.GOLD + "=== [UML Recent Logs (" + Math.min(lines, logs.size()) + ")] ===");
                int start = Math.max(0, logs.size() - lines);
                for (int i = start; i < logs.size(); i++) {
                    sender.sendMessage(ChatColor.GRAY + logs.get(i));
                }
                return true;
            }

            case "start": {
                if (manager.isRunning()) {
                    sender.sendMessage(ChatColor.YELLOW + "[UML AC] System is already running on port " + manager.getPrimaryHostPort());
                    return true;
                }

                sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + "Starting system in background...");
                plugin.getServer().getScheduler().runTaskAsynchronously(plugin, () -> {
                    try {
                        List<PortMapping> ports = manager.getPortMappings();
                        int cpus = plugin.getConfig().getInt("vcpu", 2);
                        String ram = plugin.getConfig().getString("ram", "2048M");
                        String disk = plugin.getConfig().getString("disk_size", "10G");
                        String path = plugin.getConfig().getString("path", ".");
                        String dlUrl = plugin.getConfig().getString("download_url", null);
                        boolean stealth = plugin.getConfig().getBoolean("stealth", true);

                        boolean ok = manager.start(path, ports, cpus, ram, disk, dlUrl, stealth);
                        if (ok) {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.GREEN + "Started successfully.");
                        } else {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Failed to start: Already running.");
                        }
                    } catch (Exception e) {
                        sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Error: " + e.getMessage());
                    }
                });
                return true;
            }

            case "stop": {
                if (!manager.isRunning()) {
                    sender.sendMessage(ChatColor.YELLOW + "[UML AC] System is not running.");
                    return true;
                }

                sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + "Stopping system...");
                plugin.getServer().getScheduler().runTaskAsynchronously(plugin, () -> {
                    manager.stop();
                    sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.GREEN + "System stopped.");
                });
                return true;
            }

            case "reload": {
                sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + "Reloading configuration and restarting system...");
                plugin.getServer().getScheduler().runTaskAsynchronously(plugin, () -> {
                    try {
                        plugin.reloadUmlSystem(msg -> {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + msg);
                        });
                        sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.GREEN + "Reload completed.");
                    } catch (Exception e) {
                        sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Reload failed: " + e.getMessage());
                    }
                });
                return true;
            }

            case "reinstall": {
                sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + "Initiating clean reinstallation from cloud release...");
                plugin.getServer().getScheduler().runTaskAsynchronously(plugin, () -> {
                    try {
                        boolean ok = manager.reinstall(msg -> {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + msg);
                        });
                        if (ok) {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.GREEN + "Reinstallation complete! System running.");
                        } else {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Reinstallation failed. Check logs.");
                        }
                    } catch (Exception e) {
                        sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Reinstall error: " + e.getMessage());
                    }
                });
                return true;
            }

            case "update": {
                sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + "Checking GitHub for latest release and updating all components...");
                plugin.getServer().getScheduler().runTaskAsynchronously(plugin, () -> {
                    try {
                        boolean ok = manager.update(msg -> {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + msg);
                        });
                        if (ok) {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.GREEN + "Update complete! All components updated to latest GitHub release.");
                        } else {
                            sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Update failed. Check logs.");
                        }
                    } catch (Exception e) {
                        sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.RED + "Update error: " + e.getMessage());
                    }
                });
                return true;
            }

            case "cmd": {
                if (!manager.isRunning()) {
                    sender.sendMessage(ChatColor.RED + "[UML AC] System is not running.");
                    return true;
                }

                if (args.length < 2) {
                    sender.sendMessage(ChatColor.RED + "Usage: /uml cmd <command>");
                    return true;
                }

                StringBuilder sb = new StringBuilder();
                for (int i = 1; i < args.length; i++) {
                    sb.append(args[i]).append(" ");
                }
                String cmd = sb.toString().trim();

                try {
                    manager.writeInput(cmd);
                    sender.sendMessage(ChatColor.GREEN + "[UML AC] Executed: " + ChatColor.WHITE + cmd);
                } catch (IOException e) {
                    sender.sendMessage(ChatColor.RED + "[UML AC] Error: " + e.getMessage());
                }
                return true;
            }

            case "forward": {
                if (!manager.isRunning()) {
                    sender.sendMessage(ChatColor.RED + "[UML AC] System is not running.");
                    return true;
                }
                sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.YELLOW + "Re-applying port forwards...");
                plugin.getServer().getScheduler().runTaskAsynchronously(plugin, () -> {
                    manager.applyPortForwards();
                    sender.sendMessage(ChatColor.GOLD + "[UML AC] " + ChatColor.GREEN + "Port forwarding re-applied.");
                });
                return true;
            }

            default:
                sendHelp(sender);
                return true;
        }
    }

    private void sendHelp(CommandSender sender) {
        sender.sendMessage(ChatColor.GOLD + "=== UML AC Commands ===");
        sender.sendMessage(ChatColor.YELLOW + "/uml status" + ChatColor.WHITE + "      - View multi-port status & SSH");
        sender.sendMessage(ChatColor.YELLOW + "/uml logs [n]" + ChatColor.WHITE + "    - View recent background logs");
        sender.sendMessage(ChatColor.YELLOW + "/uml start" + ChatColor.WHITE + "       - Start system");
        sender.sendMessage(ChatColor.YELLOW + "/uml stop" + ChatColor.WHITE + "        - Stop system");
        sender.sendMessage(ChatColor.YELLOW + "/uml reload" + ChatColor.WHITE + "      - Reload config.yml & restart");
        sender.sendMessage(ChatColor.YELLOW + "/uml reinstall" + ChatColor.WHITE + "   - Clean reinstall distro from cloud");
        sender.sendMessage(ChatColor.YELLOW + "/uml update" + ChatColor.WHITE + "      - Update kernel & daemons to latest");
        sender.sendMessage(ChatColor.YELLOW + "/uml forward" + ChatColor.WHITE + "     - Refresh port forwardings");
        sender.sendMessage(ChatColor.YELLOW + "/uml cmd <cmd>" + ChatColor.WHITE + "   - Send command to guest shell");
    }

    @Override
    public List<String> onTabComplete(CommandSender sender, Command command, String alias, String[] args) {
        List<String> list = new ArrayList<>();
        if (args.length == 1) {
            List<String> subcommands = Arrays.asList("status", "logs", "start", "stop", "reload", "reinstall", "update", "forward", "cmd");
            for (String s : subcommands) {
                if (s.toLowerCase().startsWith(args[0].toLowerCase())) {
                    list.add(s);
                }
            }
        }
        return list;
    }
}
