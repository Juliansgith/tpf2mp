// Read-only export from an analyzed Ghidra project. Never patches the executable.
// @category TPF2MP.Investigation
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

public class ExportNativePerformance extends GhidraScript {
    private final Map<Address, String> selected = new LinkedHashMap<>();
    private final Map<String, Integer> counts = new HashMap<>();
    private PrintWriter references;

    private String category(String text) {
        String lower = text.toLowerCase(Locale.ROOT);
        if (lower.contains("simpersondestination")) return "agent-config";
        if (lower.contains("simpersonsystem::update") || lower.contains("simpersonatterminalsystem::update")
            || lower.contains("simpersoncachesystem::update")) return "agent-update";
        if (lower.contains("threadpool") && (lower.contains("simperson") || lower.contains("ecs::"))) return "simulation-workers";
        if (lower.contains("pathfind") || lower.contains("pathsearch")) return "pathfinding";
        if (lower.contains("threadpool") || lower.contains("hardware_concurrency")) return "thread-pool";
        if (lower.contains("buildproposal") || lower.contains("proposalpreview")) return "construction";
        if (lower.contains("heapalloc") || lower.contains("heaprealloc") || lower.contains("malloc") || lower.contains("heapcreate")) return "allocation";
        return null;
    }

    private void exportReferences(Address address, String label, String group) {
        ReferenceIterator iterator = currentProgram.getReferenceManager().getReferencesTo(address);
        while (iterator.hasNext()) {
            Reference reference = iterator.next();
            Function function = getFunctionContaining(reference.getFromAddress());
            references.printf("%s\t%s\t%s\t%s\t%s%n", group, address,
                reference.getFromAddress(), function == null ? "no-function" : function.getEntryPoint(),
                label.replace('\t', ' ').replace('\n', ' ').replace('\r', ' '));
            int count = counts.getOrDefault(group, 0);
            if (function != null && !function.isExternal() && !selected.containsKey(function.getEntryPoint()) && count < 8) {
                selected.put(function.getEntryPoint(), group + " " + label);
                counts.put(group, count + 1);
            }
        }
    }

    public void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 1) throw new IllegalArgumentException("Output directory required");
        Path output = Path.of(arguments[0]);
        Files.createDirectories(output);
        try (PrintWriter writer = new PrintWriter(Files.newBufferedWriter(output.resolve("references.tsv"), StandardCharsets.UTF_8))) {
            references = writer;
            writer.println("category\ttarget\treference\tfunction\tlabel");
            DataIterator data = currentProgram.getListing().getDefinedData(true);
            while (data.hasNext()) {
                monitor.checkCancelled();
                Data item = data.next();
                Object value = item.getValue();
                if (!(value instanceof String)) continue;
                String label = (String)value;
                String group = category(label);
                if (group != null) exportReferences(item.getAddress(), label, group);
            }
            SymbolIterator symbols = currentProgram.getSymbolTable().getAllSymbols(true);
            while (symbols.hasNext()) {
                monitor.checkCancelled();
                Symbol symbol = symbols.next();
                String group = category(symbol.getName());
                if (group != null) exportReferences(symbol.getAddress(), symbol.getName(), group);
            }
        }
        long[] pinnedRvas = {0x9d6440L, 0x9da290L, 0x9d2cf0L};
        String[] pinnedNames = {"BuildProposalVisitor", "ApplyCommand", "CommandList_Swap"};
        for (int index = 0; index < pinnedRvas.length; index++) {
            Address address = currentProgram.getImageBase().add(pinnedRvas[index]);
            Function function = getFunctionAt(address);
            if (function != null) selected.put(address, "pinned-build35924 " + pinnedNames[index]);
        }
        DecompInterface decompiler = new DecompInterface();
        try (PrintWriter inventory = new PrintWriter(Files.newBufferedWriter(output.resolve("functions.tsv"), StandardCharsets.UTF_8))) {
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException("Decompiler could not open program");
            inventory.println("entry\tsize\tcompleted\treason\tevidence");
            for (Map.Entry<Address, String> entry : selected.entrySet()) {
                monitor.checkCancelled();
                Function function = getFunctionAt(entry.getKey());
                DecompileResults result = decompiler.decompileFunction(function, 30, monitor);
                inventory.printf("%s\t%d\t%s\t%s\t%s%n", entry.getKey(), function.getBody().getNumAddresses(),
                    result.decompileCompleted(), result.getErrorMessage().replace('\n', ' '), entry.getValue());
                inventory.flush();
                if (result.decompileCompleted()) {
                    Files.writeString(output.resolve("function_" + entry.getKey() + ".c"),
                        "/* Inferred pseudocode, not original or rebuildable source.\nEvidence: " + entry.getValue().replace("*/", "* /")
                        + "\n*/\n" + result.getDecompiledFunction().getC(), StandardCharsets.UTF_8);
                }
                println("TPF2MP_EXPORT " + entry.getKey() + " completed=" + result.decompileCompleted());
            }
        } finally { decompiler.dispose(); }
        println("TPF2MP_EXPORT_DONE selected=" + selected.size() + " knownFunctions=" + currentProgram.getFunctionManager().getFunctionCount());
    }
}
