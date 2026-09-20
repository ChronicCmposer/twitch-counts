// ghidra_decompile.java — print decompiled C for one or more functions.
//
// Driven by analyzeHeadless (see the Makefile `decompile` target):
//   analyzeHeadless <proj> <name> -import <bin> \
//     -scriptPath scripts -postScript ghidra_decompile.java [FUNC ...]
//
// Each FUNC is a selector: a symbol name or a hex address (0x...).  Selectors
// are matched against top-level functions; on a miss the script prints the
// function directory (name @ entry) so the caller can pick a real one.  This
// matters because the project's Linux binaries are stripped (-s), so `main`
// has no symbol and Ghidra names its functions FUN_<addr>.
//
// Java (not Jython): Ghidra 12 removed the Jython runtime, and .py scripts
// need a separate PyGhidra install that this headless environment does not
// set up.  A GhidraScript always runs headless with no external runtime.
//
// Uses FlatDecompilerAPI with an explicit FlatProgramAPI, which the no-arg
// constructor requires for initialize().
//
// NOTE: decompilation needs Ghidra's NATIVE decompiler for the host.  Ghidra
// ships those only for x86_64 Linux/Windows and macOS; aarch64 Linux does not,
// so `make decompile` refuses to run there — use `make disasm` instead.
//
// Fails loudly (throws) when a selector cannot be resolved or the decompiler
// cannot complete, so callers never mistake silence for success.

import ghidra.app.decompiler.flatapi.FlatDecompilerAPI;
import ghidra.app.script.GhidraScript;
import ghidra.program.flatapi.FlatProgramAPI;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;

public class ghidra_decompile extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] names = getScriptArgs();
        if (names == null || names.length == 0) {
            names = new String[] { "main" };
        }

        FlatProgramAPI flatApi = new FlatProgramAPI(currentProgram, monitor);
        FlatDecompilerAPI decompiler = new FlatDecompilerAPI(flatApi);
        decompiler.initialize();

        boolean failed = false;
        try {
            FunctionManager fm = currentProgram.getFunctionManager();
            for (String name : names) {
                Function fn = findFunction(fm, name);
                if (fn == null) {
                    println("ghidra_decompile: selector not resolved to a function: " + name);
                    listFunctions(fm);
                    failed = true;
                    continue;
                }
                try {
                    println(decompiler.decompile(fn));
                } catch (Exception e) {
                    println("ghidra_decompile: decompile failed: " + name + ": " + e.getMessage());
                    failed = true;
                }
            }
        } finally {
            decompiler.dispose();
        }

        if (failed) {
            throw new RuntimeException("ghidra_decompile: one or more functions failed");
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