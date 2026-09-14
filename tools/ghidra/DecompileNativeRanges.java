// Targeted analysis in a disposable Ghidra database; never writes the input PE.
// Arguments: output directory, then VA:byteLength ranges from x64 unwind metadata.
// @category TPF2MP.Investigation
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import java.nio.file.Path;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;

public class DecompileNativeRanges extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) throw new IllegalArgumentException("Output and VA:length ranges required");
        Path output = Path.of(args[0]);
        Files.createDirectories(output);
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException("Open program failed");
            for (int i = 1; i < args.length; i++) {
                monitor.checkCancelled();
                String[] pair = args[i].split(":");
                Address start = toAddr(Long.decode(pair[0]));
                long size = Long.decode(pair[1]);
                if (size < 1 || size > 100000) throw new IllegalArgumentException("Range must be 1..100000 bytes");
                AddressSet body = new AddressSet(start, start.add(size - 1));
                new DisassembleCommand(start, body, true).applyTo(currentProgram, monitor);
                Function function = getFunctionAt(start);
                if (function == null) function = createFunction(start, null);
                if (function == null) throw new IllegalStateException("Cannot create function at " + start);
                function.setBody(body);
                decompiler.flushCache();
                DecompileResults result = decompiler.decompileFunction(function, 60, monitor);
                String text = result.decompileCompleted() ? result.getDecompiledFunction().getC() : result.getErrorMessage();
                Files.writeString(output.resolve("function_" + start + ".c"),
                    "/* Inferred pseudocode from bounded unwind range; may be a fragment. Not original source. */\n" + text,
                    StandardCharsets.UTF_8);
                println("TPF2MP_TARGET " + start + " size=" + size + " completed=" + result.decompileCompleted());
            }
        } finally { decompiler.dispose(); }
    }
}
