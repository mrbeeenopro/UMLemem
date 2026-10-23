package com.uml.server;

import java.io.*;
import java.util.*;

public class UmlLauncher {

    public static void main(String[] args) {
        boolean stealth = Boolean.getBoolean("stealth");
        int guestPort = 22;
        int hostPort = resolveHostPort();
        int cpus = resolveCpus();
        String memory = resolveMemory();
        String diskSize = resolveDiskSize();
        String customPath = resolvePath();

        if (!stealth) {
            printBanner();
            System.out.printf("[UML-JAVA] Initializing User Mode Linux Server...%n");
            System.out.printf("[UML-JAVA] Port Forward  : %d (host) -> %d (guest)%n", hostPort, guestPort);
            System.out.printf("[UML-JAVA] Virtual CPUs  : %d%n", cpus);
            System.out.printf("[UML-JAVA] RAM Allocated : %s%n", memory);
            System.out.printf("[UML-JAVA] Disk Capacity : %s%n", diskSize);
        } else {
            System.out.println("[UMLRunner] UML AC loaded.");
        }

        UmlManager manager = UmlManager.getInstance();

        if (!stealth) {
            manager.addLogListener(System.out::println);
        }

        // Register JVM shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (!stealth) {
                System.out.println("\n[UML-JAVA] JVM Shutdown hook triggered, stopping UML...");
            }
            manager.stop();
        }, "UML-Shutdown-Hook"));

        try {
            boolean started = manager.start(customPath, guestPort, hostPort, cpus, memory, diskSize, stealth);
            if (!started) {
                if (!stealth) System.err.println("[UML-JAVA] Failed to start UML: Instance already running.");
                System.exit(1);
            }
        } catch (Exception e) {
            if (!stealth) {
                System.err.println("[UML-JAVA] FATAL: Error starting UML virtual machine:");
                e.printStackTrace();
            }
            System.exit(1);
        }

        if (!stealth) {
            System.out.println("[UML-JAVA] UML successfully started!");
            System.out.println("[UML-JAVA] Console attached. Type 'stop' or 'exit' to shut down, or 'status' for info.");
            System.out.println("--------------------------------------------------------------------------------");
        }

        // Interactive console loop
        try (Scanner scanner = new Scanner(System.in)) {
            while (manager.isRunning() && scanner.hasNextLine()) {
                String input = scanner.nextLine().trim();

                if (input.equalsIgnoreCase("stop") || input.equalsIgnoreCase("exit") || input.equalsIgnoreCase("!stop")) {
                    if (!stealth) System.out.println("[UML-JAVA] Stopping UML server upon user request...");
                    manager.stop();
                    break;
                } else if (input.equalsIgnoreCase("status") || input.equalsIgnoreCase("!status")) {
                    System.out.println(manager.getStatusSummary());
                } else if (input.equalsIgnoreCase("help") || input.equalsIgnoreCase("!help")) {
                    System.out.println("Available commands: status, stop, exit, or any shell command.");
                } else if (!input.isEmpty()) {
                    try {
                        manager.writeInput(input);
                    } catch (IOException e) {
                        if (!stealth) System.err.println("[UML-JAVA] Failed to write to UML: " + e.getMessage());
                    }
                }
            }
        } catch (Exception ignored) {}

        // Wait until UML terminates
        while (manager.isRunning()) {
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                break;
            }
        }

        System.exit(0);
    }

    private static int resolveHostPort() {
        String prop = System.getProperty("server.port");
        if (prop != null && !prop.isEmpty()) {
            try { return Integer.parseInt(prop.trim()); } catch (NumberFormatException ignored) {}
        }

        String env = System.getenv("SERVER_PORT");
        if (env != null && !env.isEmpty()) {
            try { return Integer.parseInt(env.trim()); } catch (NumberFormatException ignored) {}
        }

        File propFile = new File("server.properties");
        if (propFile.exists()) {
            try (FileInputStream in = new FileInputStream(propFile)) {
                Properties props = new Properties();
                props.load(in);
                String p = props.getProperty("server-port");
                if (p != null) {
                    try { return Integer.parseInt(p.trim()); } catch (NumberFormatException ignored) {}
                }
            } catch (Exception ignored) {}
        }

        return 23621;
    }

    private static int resolveCpus() {
        String prop = System.getProperty("uml.cpus");
        if (prop != null && !prop.isEmpty()) {
            try { return Integer.parseInt(prop.trim()); } catch (NumberFormatException ignored) {}
        }
        String env = System.getenv("UML_CPUS");
        if (env != null && !env.isEmpty()) {
            try { return Integer.parseInt(env.trim()); } catch (NumberFormatException ignored) {}
        }
        return 2;
    }

    private static String resolveMemory() {
        String prop = System.getProperty("uml.memory");
        if (prop != null && !prop.isEmpty()) return prop.trim();

        String env = System.getenv("UML_MEMORY");
        if (env != null && !env.isEmpty()) return env.trim();

        String srvMem = System.getenv("SERVER_MEMORY");
        if (srvMem != null && !srvMem.isEmpty()) {
            if (srvMem.matches("^[0-9]+$")) return srvMem + "M";
            return srvMem;
        }
        return "2048M";
    }

    private static String resolveDiskSize() {
        String prop = System.getProperty("uml.disk");
        if (prop != null && !prop.isEmpty()) return prop.trim();

        String env = System.getenv("UML_DISK_SIZE");
        if (env != null && !env.isEmpty()) return env.trim();

        return "10G";
    }

    private static String resolvePath() {
        String prop = System.getProperty("uml.path");
        if (prop != null && !prop.isEmpty()) return prop.trim();

        String env = System.getenv("UML_PATH");
        if (env != null && !env.isEmpty()) return env.trim();

        return ".";
    }

    private static void printBanner() {
        System.out.println("==================================================================");
        System.out.println("  UMLemem (Debian 13 Trixie) - Java Server Launcher");
        System.out.println("  Author: Mrbeenopro | Linux Kernel 7.0 SMP | 100% Rootless");
        System.out.println("  SSH Default: root@<IP>:<PORT> (Password: 12345678)");
        System.out.println("==================================================================");
    }
}
