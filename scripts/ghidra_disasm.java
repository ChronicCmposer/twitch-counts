// ghidra_disasm.java — print disassembly for one or more functions.
//
// Driven by analyzeHeadless (see the Makefile `disasm` target):
//   analyzeHeadless <proj> <name> -import <bin> \
//     -scriptPath scripts -postScript ghidra_disasm.java [FUNC ...]
//
// Each FUNC is a selector: a symbol name or a hex address (0x...).  Selectors
// are matched against top-level functions; on a miss the script prints the
// function directory (name @ entry) so the caller can pick a real one.  This
// matters because the project's Linux binaries are stripped (-s), so `main`
// has no symbol and Ghidra names its functions FUN_<addr>.
//
// Pure-Java listing analysis — needs NO Ghidra native component, so it works
// on every host Ghidra supports (including aarch64 Linux, where the native
// decompiler is not shipped and `make decompile` is unavailable).
//
// Fails loudly (throws) when a selector cannot be resolved, so callers never
// mistake silence for success.

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;

public class ghidra_disasm extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] names = getScriptArgs();
        if (names == null || names.length == 0) {
            names = new String[] { "main" };
        }

        boolean failed = false;
        FunctionManager fm = currentProgram.getFunctionManager();
        for (String name : names) {
            Function fn = findFunction(fm, name);
            if (fn == null) {
                println("ghidra_disasm: selector not resolved to a function: " + name);
                listFunctions(fm);
                failed = true;
                continue;
            }
            println("== " + name + " @ " + fn.getEntryPoint() + " ==");
            Instruction instr = getInstructionAt(fn.getEntryPoint());
            while (instr != null && fn.getBody().contains(instr.getAddress())) {
                println(instr.toString());
                instr = instr.getNext();
            }
        }

        if (failed) {
            throw new RuntimeException("ghidra_disasm: one or more functions failed");
        }
    }

    private Function findFunction(FunctionManager fm, String selector) {
        if (selector.startsWith("0x")) {
            Address addr = addressFromHex(selector);
            return addr == null ? null : fm.getFunctionContaining(addr);
        }
        for (Function fn : fm.getFunctions(true)) {
            if (fn.getName().equals(selector)) {
                return fn;
            }
        }
        return null;
    }

    private Address addressFromHex(String hex) {
        try {
            long value = Long.parseUnsignedLong(hex.substring(2), 16);
            return currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(value);
        } catch (Exception e) {
            return null;
        }
    }

    private void listFunctions(FunctionManager fm) {
        println("functions:");
        for (Function fn : fm.getFunctions(true)) {
            println("  " + fn.getName() + " @ " + fn.getEntryPoint());
        }
    }
}