// Read-only export of explicitly sampled RVAs; never patches the input binary.
// @category TPF2MP.Investigation
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.Reference;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
public class ExportProfileTargets extends GhidraScript {
  public void run() throws Exception {
    String[] args=getScriptArgs();
    if(args.length<2) throw new IllegalArgumentException("Output directory and sampled RVAs required");
    Path out=Path.of(args[0]); Files.createDirectories(out);
    StringBuilder index=new StringBuilder("rva\tfunction\tname\tstringReference\n");
    DecompInterface decompiler=new DecompInterface();
    try {
      if(!decompiler.openProgram(currentProgram)) throw new IllegalStateException("Cannot open program");
      for(int i=1;i<args.length;i++) {
        var address=currentProgram.getImageBase().add(Long.decode(args[i]));
        Function f=getFunctionContaining(address);
        if(f==null) { index.append(args[i]+"\tmissing\n"); continue; }
        index.append(args[i]+"\t"+f.getEntryPoint()+"\t"+f.getName()+"\t\n");
        var instructions=currentProgram.getListing().getInstructions(f.getBody(),true);
        while(instructions.hasNext()) for(Reference ref:instructions.next().getReferencesFrom()) {
          Data data=getDataAt(ref.getToAddress());
          if(data!=null && data.getValue() instanceof String) {
            String s=((String)data.getValue()).replace('\n',' ').replace('\t',' ');
            index.append(args[i]+"\t"+f.getEntryPoint()+"\t\t"+s.substring(0,Math.min(500,s.length()))+"\n");
          }
        }
        var result=decompiler.decompileFunction(f,30,monitor);
        Files.writeString(out.resolve(f.getEntryPoint()+".c"),result.decompileCompleted()
          ? result.getDecompiledFunction().getC() : result.getErrorMessage(),StandardCharsets.UTF_8);
      }
    } finally { decompiler.dispose(); }
    Files.writeString(out.resolve("index.tsv"),index,StandardCharsets.UTF_8);
  }
}
