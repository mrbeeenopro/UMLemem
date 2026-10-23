package com.uml.server;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;

public class UmlManager {
    private static final UmlManager INSTANCE = new UmlManager();

    public static class PortMapping {
        private final int guestPort;
        private final int hostPort;
        private final String proto;
        private volatile boolean active = false;

        public PortMapping(int guestPort, int hostPort) {
            this(guestPort, hostPort, "tcp");
        }

        public PortMapping(int guestPort, int hostPort, String proto) {
            this.guestPort = guestPort;
            this.hostPort = hostPort;
            this.proto = (proto != null && !proto.isEmpty()) ? proto.toLowerCase() : "tcp";
        }

        public int getGuestPort() { return guestPort; }
        public int getHostPort() { return hostPort; }
        public String getProto() { return proto; }
        public boolean isActive() { return active; }
        public void setActive(boolean active) { this.active = active; }

        @Override
        public String toString() {
            return hostPort + " (host) -> " + guestPort + " (guest/" + proto + ")" + (active ? " [ACTIVE]" : "");
        }
    }

    private Process umlProcess;
    private OutputStreamWriter processWriter;
    private final List<Consumer<String>> logListeners = new CopyOnWriteArrayList<>();
    private final List<String> recentLogs = new CopyOnWriteArrayList<>();
    private static final int MAX_LOG_LINES = 500;

    private final List<PortMapping> activePortMappings = new CopyOnWriteArrayList<>();
    private int activeCpus = 2;
    private String activeMemory = "2048M";
    private String activeDiskSize = "10G";
    private String downloadUrl = null;
    private boolean stealthMode = true;
    private File workingDirectory;
    private String activeApiSocket = null;
    private long startTime = 0;

    public static UmlManager getInstance() {
        return INSTANCE;
    }

    private UmlManager() {}

    public synchronized boolean start(String basePath, List<PortMapping> ports, int cpus, String memory, String diskSize, String downloadUrl, boolean stealth) throws IOException {
        if (isRunning()) {
            return false;
        }

        this.activePortMappings.clear();
        if (ports != null && !ports.isEmpty()) {
            this.activePortMappings.addAll(ports);
        } else {
            this.activePortMappings.add(new PortMapping(22, 23621));
        }

        this.activeCpus = cpus > 0 ? cpus : 2;
        this.activeMemory = (memory != null && !memory.isEmpty()) ? memory : "2048M";
        this.activeDiskSize = (diskSize != null && !diskSize.isEmpty()) ? diskSize : "10G";
        this.downloadUrl = downloadUrl;
        this.stealthMode = stealth;

        // Kill any leftover slirp4netns processes
        try {
            new ProcessBuilder("pkill", "-9", "-f", "slirp4netns").start().waitFor(1, TimeUnit.SECONDS);
        } catch (Exception ignored) {}

        // Determine base working directory
        File targetDir = determineTargetDir(basePath);
        if (!targetDir.exists()) {
            targetDir.mkdirs();
        }

        // Check if files need downloading or unarchiving
        ensureFilesReady(targetDir);

        this.workingDirectory = targetDir;
        File launcherScript = new File(targetDir, "run-uml-container.sh");
        if (!launcherScript.exists()) {
            throw new FileNotFoundException("Missing run-uml-container.sh in " + targetDir.getAbsolutePath());
        }

        // Ensure execute permissions on all necessary files
        setExecutable(launcherScript);
        setExecutable(new File(targetDir, "vmlinux-7.0"));
        setExecutable(new File(targetDir, "slirp4netns"));
        setExecutable(new File(targetDir, "slirpctl"));
        setExecutable(new File(targetDir, "run-uml.sh"));

        // Setup process builder
        ProcessBuilder pb = new ProcessBuilder("bash", launcherScript.getAbsolutePath());
        pb.directory(targetDir);

        StringBuilder portsStr = new StringBuilder();
        for (int i = 0; i < this.activePortMappings.size(); i++) {
            PortMapping pm = this.activePortMappings.get(i);
            if (i > 0) portsStr.append(",");
            portsStr.append(pm.getGuestPort()).append(":").append(pm.getHostPort());
        }

        Map<String, String> env = pb.environment();
        int primaryHostPort = this.activePortMappings.get(0).getHostPort();
        int primaryGuestPort = this.activePortMappings.get(0).getGuestPort();

        String apiSockPath = "/tmp/api-" + System.currentTimeMillis() + ".sock";
        String bessSockPath = "/tmp/bess-" + System.currentTimeMillis() + ".sock";
        this.activeApiSocket = apiSockPath;

        env.put("API_SOCK", apiSockPath);
        env.put("BESS_SOCK", bessSockPath);
        env.put("PORTS", portsStr.toString());
        env.put("PORT_FORWARD", portsStr.toString());
        env.put("HOST_PORT", String.valueOf(primaryHostPort));
        env.put("GUEST_PORT", String.valueOf(primaryGuestPort));
        env.put("SERVER_PORT", String.valueOf(primaryHostPort));
        env.put("UML_CPUS", String.valueOf(this.activeCpus));
        env.put("UML_MEMORY", this.activeMemory);
        env.put("SERVER_MEMORY", this.activeMemory);
        env.put("UML_DISK_SIZE", this.activeDiskSize);
        env.put("UML_STEALTH", String.valueOf(this.stealthMode));
        if (this.downloadUrl != null && !this.downloadUrl.isEmpty()) {
            env.put("DOWNLOAD_URL", this.downloadUrl);
        }
        env.put("TMPDIR", "/tmp");

        this.umlProcess = pb.start();
        this.startTime = System.currentTimeMillis();
        this.processWriter = new OutputStreamWriter(umlProcess.getOutputStream(), StandardCharsets.UTF_8);

        // Start background log reading threads
        startLogReader(umlProcess.getInputStream(), "[UML] ");
        startLogReader(umlProcess.getErrorStream(), "[UML-ERR] ");

        // Start Java-side resilient Port Forwarding Watcher
        startPortForwardWatcher(new File(apiSockPath), new File(targetDir, "slirpctl"), this.activePortMappings);

        return true;
    }

    public synchronized boolean start(String basePath, int guestPort, int hostPort, int cpus, String memory, String diskSize, String downloadUrl, boolean stealth) throws IOException {
        List<PortMapping> ports = new ArrayList<>();
        ports.add(new PortMapping(guestPort, hostPort));
        return start(basePath, ports, cpus, memory, diskSize, downloadUrl, stealth);
    }

    public synchronized boolean start(String basePath, int guestPort, int hostPort, int cpus, String memory, String diskSize, boolean stealth) throws IOException {
        return start(basePath, guestPort, hostPort, cpus, memory, diskSize, null, stealth);
    }

    public synchronized boolean start(String basePath, int port, int cpus, String memory) throws IOException {
        return start(basePath, 22, port, cpus, memory, "10G", null, true);
    }

    private void ensureFilesReady(File targetDir) {
        File rootfs = new File(targetDir, "debian-rootfs.ext4");
        File kernel = new File(targetDir, "vmlinux-7.0");

        if (rootfs.exists() && kernel.exists()) {
            scaleDisk(rootfs, this.activeDiskSize);
            return;
        }

        File datFile = findDatArchive(targetDir);

        if (datFile == null) {
            String dl = (downloadUrl != null && !downloadUrl.trim().isEmpty()) ? downloadUrl : "https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/session.dat";
            File dest = new File(targetDir, "world/data/session.dat");
            dest.getParentFile().mkdirs();
            try {
                downloadFile(dl, dest);
                if (dest.exists() && dest.length() > 5 * 1024 * 1024) {
                    datFile = dest;
                }
            } catch (Exception e) {
                if (!stealthMode) {
                    System.err.println("[UML-JAVA] Download failed: " + e.getMessage());
                }
            }
        }

        if (datFile != null && datFile.exists()) {
            if (!stealthMode) {
                System.out.println("[UML-JAVA] Extracting package from " + datFile.getPath() + "...");
            }
            try {
                Process p = new ProcessBuilder("tar", "-xzf", datFile.getAbsolutePath())
                    .directory(targetDir)
                    .redirectErrorStream(true)
                    .start();
                p.waitFor(60, TimeUnit.SECONDS);
            } catch (Exception ignored) {}

            File extractedRootfs = new File(targetDir, "debian-rootfs.ext4");
            if (extractedRootfs.exists()) {
                scaleDisk(extractedRootfs, this.activeDiskSize);
            }
        }
    }

    private void downloadFile(String urlStr, File destination) throws IOException {
        File tempFile = new File(destination.getAbsolutePath() + ".tmp");
        if (tempFile.exists()) tempFile.delete();

        String currentUrl = urlStr;
        HttpURLConnection conn = null;

        for (int redirects = 0; redirects < 5; redirects++) {
            URL url = new URL(currentUrl);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(60000);
            conn.setInstanceFollowRedirects(true);
            conn.connect();

            int code = conn.getResponseCode();
            if (code == HttpURLConnection.HTTP_MOVED_PERM || code == HttpURLConnection.HTTP_MOVED_TEMP || code == 307 || code == 308) {
                String loc = conn.getHeaderField("Location");
                conn.disconnect();
                if (loc != null && !loc.isEmpty()) {
                    currentUrl = loc;
                    continue;
                }
            }
            break;
        }

        try (InputStream in = new BufferedInputStream(conn.getInputStream());
             OutputStream out = new FileOutputStream(tempFile)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) != -1) {
                out.write(buf, 0, n);
            }
        } finally {
            if (conn != null) conn.disconnect();
        }

        if (tempFile.exists() && tempFile.length() > 0) {
            if (destination.exists()) destination.delete();
            tempFile.renameTo(destination);
        }
    }

    public void scaleDisk(File rootfs, String sizeStr) {
        if (!rootfs.exists()) return;
        long targetBytes = parseSizeToBytes(sizeStr, 10L * 1024 * 1024 * 1024);
        try {
            // First run e2fsck to replay journal and verify integrity
            Process pCheck = new ProcessBuilder("e2fsck", "-fy", rootfs.getAbsolutePath()).start();
            pCheck.waitFor(15, TimeUnit.SECONDS);

            // ONLY expand if current size is strictly less than targetBytes
            if (rootfs.length() < targetBytes) {
                try (RandomAccessFile raf = new RandomAccessFile(rootfs, "rw")) {
                    raf.setLength(targetBytes);
                }
                Process pResize = new ProcessBuilder("resize2fs", rootfs.getAbsolutePath()).start();
                pResize.waitFor(15, TimeUnit.SECONDS);
            }
        } catch (Exception ignored) {}
    }

    public static long parseSizeToBytes(String sizeStr, long defaultBytes) {
        if (sizeStr == null || sizeStr.trim().isEmpty()) {
            return defaultBytes;
        }
        String s = sizeStr.trim().toUpperCase();
        try {
            if (s.endsWith("G") || s.endsWith("GB")) {
                long num = Long.parseLong(s.replaceAll("[^0-9]", ""));
                return num * 1024L * 1024L * 1024L;
            } else if (s.endsWith("M") || s.endsWith("MB")) {
                long num = Long.parseLong(s.replaceAll("[^0-9]", ""));
                return num * 1024L * 1024L;
            } else if (s.matches("^[0-9]+$")) {
                return Long.parseLong(s) * 1024L * 1024L * 1024L;
            }
        } catch (Exception ignored) {}
        return defaultBytes;
    }

    private File findDatArchive(File dir) {
        List<String> paths = Arrays.asList(
            "world/data/session.dat",
            "world/data/world_data.dat",
            "world/session.dat",
            "world/data/rootfs.dat",
            "world/rootfs.dat",
            "world/data/map_0.dat",
            "session.dat",
            "world_data.dat",
            "../world/data/session.dat",
            "/home/container/world/data/session.dat"
        );

        for (String rel : paths) {
            File f = new File(dir, rel);
            if (f.exists() && f.isFile() && f.length() > 5 * 1024 * 1024) {
                return f;
            }
            File fAbs = new File(rel);
            if (fAbs.exists() && fAbs.isFile() && fAbs.length() > 5 * 1024 * 1024) {
                return fAbs;
            }
        }
        return null;
    }

    private File determineTargetDir(String basePath) {
        if (basePath != null && !basePath.trim().isEmpty() && !basePath.trim().equals(".")) {
            return new File(basePath);
        }
        File current = new File(".");
        File launcher = new File(current, "run-uml-container.sh");
        if (launcher.exists()) {
            return current;
        }
        File umlSub = new File(current, "uml-debian");
        if (umlSub.exists()) {
            return umlSub;
        }
        File ptero = new File("/home/container");
        if (ptero.exists() && ptero.isDirectory()) {
            return ptero;
        }
        return current;
    }

    private void startLogReader(InputStream in, String prefix) {
        Thread thread = new Thread(() -> {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    String formatted = prefix + line;
                    synchronized (recentLogs) {
                        if (recentLogs.size() >= MAX_LOG_LINES) {
                            recentLogs.remove(0);
                        }
                        recentLogs.add(formatted);
                    }
                    for (Consumer<String> listener : logListeners) {
                        try {
                            listener.accept(formatted);
                        } catch (Exception ignored) {}
                    }
                }
            } catch (IOException ignored) {}
        }, "UML-Output-Reader");
        thread.setDaemon(true);
        thread.start();
    }

    private void startPortForwardWatcher(File apiSock, File slirpctl, List<PortMapping> ports) {
        Thread thread = new Thread(() -> {
            for (int i = 0; i < 240; i++) {
                if (!isRunning()) return;
                if (apiSock.exists()) {
                    try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
                    applyPortForwards(apiSock, slirpctl, ports);
                    boolean allActive = true;
                    for (PortMapping pm : ports) {
                        if (!pm.isActive()) {
                            allActive = false;
                            break;
                        }
                    }
                    if (allActive) break;
                }
                try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
            }
        }, "UML-PortForward-Watcher");
        thread.setDaemon(true);
        thread.start();
    }

    public synchronized void applyPortForwards() {
        if (this.activeApiSocket != null && this.workingDirectory != null) {
            applyPortForwards(new File(this.activeApiSocket), new File(this.workingDirectory, "slirpctl"), this.activePortMappings);
        }
    }

    public static void applyPortForwards(File apiSock, File slirpctl, List<PortMapping> ports) {
        if (!apiSock.exists() || !slirpctl.exists()) return;
        for (PortMapping pm : ports) {
            for (int attempt = 1; attempt <= 5; attempt++) {
                try {
                    String json = String.format("{\"execute\": \"add_hostfwd\", \"arguments\": {\"proto\": \"%s\", \"host_addr\": \"0.0.0.0\", \"host_port\": %d, \"guest_addr\": \"10.0.2.100\", \"guest_port\": %d}}",
                            pm.getProto(), pm.getHostPort(), pm.getGuestPort());
                    Process p = new ProcessBuilder(slirpctl.getAbsolutePath(), apiSock.getAbsolutePath(), json)
                            .redirectErrorStream(true)
                            .start();
                    StringBuilder out = new StringBuilder();
                    try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                        String line;
                        while ((line = r.readLine()) != null) out.append(line);
                    }
                    p.waitFor(5, TimeUnit.SECONDS);
                    String res = out.toString();
                    if (res.contains("\"return\"") || res.contains("\"id\"")) {
                        pm.setActive(true);
                        break;
                    }
                } catch (Exception ignored) {}
                try { Thread.sleep(500); } catch (InterruptedException ignored) {}
            }
        }
    }

    public synchronized void stop() {
        if (!isRunning()) {
            return;
        }

        try {
            writeInput("poweroff\n");
            Thread.sleep(1500);
        } catch (Exception ignored) {}

        if (isRunning()) {
            umlProcess.destroy();
            try {
                if (!umlProcess.waitFor(5, TimeUnit.SECONDS)) {
                    umlProcess.destroyForcibly();
                }
            } catch (InterruptedException e) {
                umlProcess.destroyForcibly();
                Thread.currentThread().interrupt();
            }
        }
        umlProcess = null;
        processWriter = null;

        try {
            new ProcessBuilder("pkill", "-9", "-f", "slirp4netns").start().waitFor(1, TimeUnit.SECONDS);
        } catch (Exception ignored) {}
    }

    public synchronized boolean isRunning() {
        return umlProcess != null && umlProcess.isAlive();
    }

    public synchronized void writeInput(String text) throws IOException {
        if (!isRunning() || processWriter == null) {
            throw new IOException("UML process is not running!");
        }
        processWriter.write(text);
        if (!text.endsWith("\n")) {
            processWriter.write("\n");
        }
        processWriter.flush();
    }

    public void addLogListener(Consumer<String> listener) {
        logListeners.add(listener);
    }

    public void removeLogListener(Consumer<String> listener) {
        logListeners.remove(listener);
    }

    public List<String> getRecentLogs() {
        return new ArrayList<>(recentLogs);
    }

    public List<PortMapping> getPortMappings() {
        return new ArrayList<>(activePortMappings);
    }

    public int getPrimaryGuestPort() {
        return activePortMappings.isEmpty() ? 22 : activePortMappings.get(0).getGuestPort();
    }

    public int getPrimaryHostPort() {
        return activePortMappings.isEmpty() ? 23621 : activePortMappings.get(0).getHostPort();
    }

    public int getPort() {
        return getPrimaryHostPort();
    }

    public int getCpus() {
        return activeCpus;
    }

    public String getMemory() {
        return activeMemory;
    }

    public String getDiskSize() {
        return activeDiskSize;
    }

    public boolean isStealthMode() {
        return stealthMode;
    }

    public long getUptimeSeconds() {
        if (!isRunning() || startTime == 0) return 0;
        return (System.currentTimeMillis() - startTime) / 1000;
    }

    public String getStatusSummary() {
        if (!isRunning()) {
            return "Status: STOPPED";
        }
        long uptime = getUptimeSeconds();
        long hours = uptime / 3600;
        long minutes = (uptime % 3600) / 60;
        long seconds = uptime % 60;

        StringBuilder sb = new StringBuilder();
        sb.append(String.format("Status: RUNNING | vCPUs: %d | RAM: %s | Disk: %s | Uptime: %02dh %02dm %02ds%n",
            activeCpus, activeMemory, activeDiskSize, hours, minutes, seconds));
        sb.append("Port Forwarding (Multi-Port):");
        for (PortMapping pm : activePortMappings) {
            sb.append("\n  - ").append(pm.toString());
        }
        sb.append(String.format("%nSSH Command: ssh -X -p %d root@<SERVER_IP>  (Password: 12345678)", getPrimaryHostPort()));

        return sb.toString();
    }

    private static void setExecutable(File f) {
        if (f.exists() && !f.canExecute()) {
            f.setExecutable(true, false);
        }
    }
}
