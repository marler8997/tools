#!/usr/bin/env rdmd
/*
 *  Copyright (C) 2008 by Andrei Alexandrescu
 *  Written by Andrei Alexandrescu, www.erdani.org
 *  Based on an idea by Georg Wrede
 *  Featuring improvements suggested by Christopher Wright
 *  Windows port using bug fixes and suggestions by Adam Ruppe
 *
 *
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

// Written in the D programming language.

import std.algorithm, std.array, core.stdc.stdlib, std.datetime,
    std.digest.md, std.exception, std.file, std.getopt,
    std.parallelism, std.path, std.process, std.range, std.regex,
    std.stdio, std.string, std.typetuple;
import std.conv : text;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
    enum libExt = ".a";
    enum altDirSeparator = "";
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
    enum libExt = ".lib";
    enum altDirSeparator = "/";
}
else
{
    static assert(0, "Unsupported operating system.");
}

private bool chatty, buildOnly, dryRun, force, preserveOutputPaths;
private string exe, userTempDir;
immutable string[] defaultExclusions = ["std", "etc", "core"];
private string[] extraExclusions;
private string[] includes;
private string[] extraFiles = [];

version (DigitalMars)
    private enum defaultCompiler = "dmd";
else version (GNU)
    private enum defaultCompiler = "gdmd";
else version (LDC)
    private enum defaultCompiler = "ldmd2";
else
    static assert(false, "Unknown compiler");

//private string compiler;

version(unittest) {} else
int main(string[] args)
{
    //writeln("Invoked with: ", args);
    if (args.length > 1 && args[1].startsWith("--shebang ", "--shebang="))
    {
        // multiple options wrapped in one
        auto a = args[1]["--shebang ".length .. $];
        args = args[0 .. 1] ~ std.string.split(a) ~ args[2 .. $];
    }

    // Continue parsing the command line; now get rdmd's own arguments

    // Parse the -o option (-ofmyfile or -odmydir).
    void dashOh(string key, string value)
    {
        if (value[0] == 'f')
        {
            // -ofmyfile passed
            exe = value[1 .. $];
        }
        else if (value[0] == 'd')
        {
            // -odmydir passed
            if (!exe.ptr) // Don't let -od override -of
            {
                // add a trailing dir separator to clarify it's a dir
                exe = value[1 .. $];
                if (!exe.endsWith(dirSeparator))
                {
                    exe ~= dirSeparator;
                }
                assert(exe.endsWith(dirSeparator));
            }
        }
        else if (value[0] == '-')
        {
            // -o- passed
            enforce(false, "Option -o- currently not supported by rdmd");
        }
        else if (value[0] == 'p')
        {
            // -op passed
            preserveOutputPaths = true;
        }
        else
        {
            enforce(false, "Unrecognized option: " ~ key ~ value);
        }
    }

    // start the web browser on documentation page
    void man()
    {
        std.process.browse("http://dlang.org/rdmd.html");
    }

    auto programPos = indexOfProgram(args);
    assert(programPos > 0);
    auto argsBeforeProgram = args[0 .. programPos];

    string compiler;
    bool bailout;    // bailout set by functions called in getopt if
                     // program should exit
    string[] loop;       // set by --loop
    bool addStubMain;// set by --main
    string[] eval;     // set by --eval
    bool makeDepend;
    string makeDepFile;
    getopt(argsBeforeProgram,
            std.getopt.config.caseSensitive,
            std.getopt.config.passThrough,
            "build-only", &buildOnly,
            "chatty", &chatty,
            "compiler", &compiler,
            "dry-run", &dryRun,
            "eval", &eval,
            "loop", &loop,
            "exclude", &extraExclusions,
            "include", &includes,
            "extra-file", &extraFiles,
            "force", &force,
            "help", { writeln(helpString); bailout = true; },
            "main", &addStubMain,
            "makedepend", &makeDepend,
            "makedepfile", &makeDepFile,
            "man", { man(); bailout = true; },
            "tmpdir", &userTempDir,
            "o", &dashOh);
    if (bailout) return 0;
    if (dryRun) chatty = true; // dry-run implies chatty

    if (!compiler)
    {
        // Look for the D compiler in the same directory as rdmd, if it doesn't exist then
        // fallback to the one in your path.
        string compilerWithPath = buildPath(dirName(thisExePath()), defaultCompiler);
        yap("stat ", compilerWithPath);
        if (compilerWithPath.exists && compilerWithPath.isFile)
            compiler = compilerWithPath;
        else
            compiler = defaultCompiler;
    }

    /* Only -of is supported because Make is very susceptible to file names, and
     * it doesn't do a good job resolving them. One option would be to use
     * std.path.buildNormalizedPath(), but some corner cases will break, so it
     * has been decided to only allow -of for now.
     * To see the full discussion please refer to:
     * https://github.com/dlang/tools/pull/122
     */
    if ((makeDepend || makeDepFile.ptr) && (!exe.ptr || exe.endsWith(dirSeparator)))
    {
        stderr.write(helpString);
        stderr.writeln();
        stderr.writeln("Missing option: --makedepend and --makedepfile need -of");
        return 1;
    }

    if (preserveOutputPaths)
    {
        argsBeforeProgram = argsBeforeProgram[0] ~ ["-op"] ~ argsBeforeProgram[1 .. $];
    }

    string root;
    string[] programArgs;
    // Just evaluate this program!
    enforce(!(loop.ptr && eval.ptr), "Cannot mix --eval and --loop.");
    if (loop.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --loop and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(importWorld ~ "void main(char[][] args) { "
                ~ "foreach (line; std.stdio.stdin.byLine()) {\n"
                ~ std.string.join(loop, "\n")
                ~ ";\n} }");
        argsBeforeProgram ~= "-d";
    }
    else if (eval.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --eval and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(importWorld ~ "void main(char[][] args) {\n"
                ~ std.string.join(eval, "\n") ~ ";\n}");
        argsBeforeProgram ~= "-d";
    }
    else if (programPos < args.length)
    {
        root = args[programPos].chomp(".d") ~ ".d";
        programArgs = args[programPos + 1 .. $];
    }
    else // no code to run
    {
        write(helpString);
        return 1;
    }

    auto
        exeBasename = root.baseName(".d"),
        exeDirname = root.dirName;

    assert(argsBeforeProgram.length >= 1);
    auto compilerFlags = argsBeforeProgram[1 .. $];

    bool obj, lib, userGenJson;
    auto jsonSettings = JsonSettings();
    foreach (compilerFlag; compilerFlags)
    {
        if (compilerFlag == "-c")
            obj = true;
        else if (compilerFlag == "-lib")
            lib = true;
        else if (compilerFlag.startsWith("-X"))
        {
            jsonSettings.enabled = true;
            auto rest = compilerFlag[2..$];
            if (rest.startsWith("f"))
            {
                rest = rest[1 .. $];
                if (rest.startsWith("="))
                    rest = rest[1 .. $];
                jsonSettings.filename = rest;
            }
        }
    }
    string outExt = lib ? libExt : obj ? objExt : binExt;
    // TODO: if user uses -i, need to add those to the includes/excludes
    //       so that they affect the dependencies propertly

    // Assume --build-only for -c and -lib.
    buildOnly |= obj || lib;

    // --build-only implies the user would like a binary in the program's directory
    if (buildOnly && !exe.ptr)
        exe = exeDirname ~ dirSeparator;

    if (exe.ptr && exe.endsWith(dirSeparator))
    {
        // user specified a directory, complete it to a file
        exe = buildPath(exe, exeBasename) ~ outExt;
    }

    // Compute the object directory and ensure it exists
    immutable workDir = getWorkPath(root, compiler, compilerFlags);
    lockWorkPath(workDir); // will be released by the OS on process exit
    string objDir = buildPath(workDir, "objs");
    yap("mkdirRecurse ", objDir);
    if (!dryRun)
        mkdirRecurse(objDir);

    if (lib)
    {
        // When using -lib, the behavior of the DMD -of switch
        // changes: instead of being relative to the current
        // directory, it becomes relative to the output directory.
        // When building libraries, DMD does not generate any object
        // files; thus, we can override objDir (which is normally a
        // temporary directory) to be the current directory, so that
        // the relative -of path becomes correct.
        objDir = ".";
    }

    auto depFilenames = DepFilenames(
        buildPath(workDir, "rdmd.deps"),
        buildPath(workDir, "lastBuild.json"));

    auto compilerInfo = getCompilerInfo(depFilenames.json, compiler);
    yap("compilerSupports -i: ", compilerInfo.supportsDashI);

    string[string] deps;
    if (!force || makeDepend || makeDepFile.ptr)
    {
        deps = tryGetDepsFromFile(root, objDir, compilerFlags, depFilenames);
    }

    Flag!"exit" writeCurrentDeps()
    {
        if (deps is null)
            return No.exit;

        // --makedepend mode. Just print dependencies and exit.
        if (makeDepend)
        {
            writeDeps(exe, root, deps, stdout);
            return Yes.exit;
        }

        // --makedepfile mode. Print dependencies to a file and continue.
        // This is similar to GCC's -MF option, very useful to update the
        // dependencies file and compile in one go:
        // -include .deps.mak
        // prog:
        //      rdmd --makedepfile=.deps.mak --build-only prog.d
        if (makeDepFile !is null)
            writeDeps(exe, root, deps, File(makeDepFile, "w"));

        return No.exit;
    }

    if (writeCurrentDeps())
        return 0;

    // Compute executable name, check for freshness, rebuild
    /*
      We need to be careful about using -o. Normally the generated
      executable is hidden in the unique directory workDir. But if the
      user forces generation in a specific place by using -od or -of,
      the time of the binary can't be used to check for freshness
      because the user may change e.g. the compile option from one run
      to the next, yet the generated binary's datetime stays the
      same. In those cases, we'll use a dedicated file called ".built"
      and placed in workDir. Upon a successful build, ".built" will be
      touched. See also
      http://d.puremagic.com/issues/show_bug.cgi?id=4814
     */
    string buildWitness;
    SysTime lastBuildTime = SysTime.min;
    if (exe.ptr)
    {
        // user-specified exe name
        buildWitness = buildPath(workDir, ".built");
        if (deps !is null && !exe.newerThan(buildWitness))
        {
            // Both exe and buildWitness exist, and exe is older than
            // buildWitness. This is the only situation in which we
            // may NOT need to recompile.
            yap("stat ", buildWitness);
            lastBuildTime = buildWitness.timeLastModified(SysTime.min);
        }
    }
    else
    {
        exe = buildPath(workDir, exeBasename) ~ outExt;
        buildWitness = exe;
        if (deps !is null)
        {
            yap("stat ", buildWitness);
            lastBuildTime = buildWitness.timeLastModified(SysTime.min);
        }
    }

    if(deps is null || chain(root.only, deps.byKey).anyNewerThan(lastBuildTime))
    {
        auto result = rebuildWithDashI(compiler, root, exe, workDir, objDir, compilerFlags,
            depFilenames.json, addStubMain, makeDepend, jsonSettings);
        if (!result.dashIError)
        {
            if (makeDepend || makeDepFile.ptr)
            {
                enforce(exists(depFilenames.json),
                    format("codebug: dep file '%s' was not created after invoking compiler", depFilenames.json));
                deps = readJsonDepsFile(objDir, depFilenames.json);
                if (writeCurrentDeps())
                    return 0;
            }
        }
        else
        {
            yap("compiler does not support '-i', falling back to 2-pass compilation");
            bool upToDate = false;
            if (deps is null)
            {
                deps = getDepsUsingCompiler(compiler, root, objDir, compilerFlags, depFilenames.verbose);
                if (makeDepend || makeDepFile.ptr)
                {
                    deps = readVerboseDepsFile(objDir, depFilenames.verbose);
                    if (writeCurrentDeps())
                        return 0;
                }
                if (!chain(root.only, deps.byKey).anyNewerThan(lastBuildTime))
                {
                    goto LupToDate;
                }
            }
            result.exitCode = rebuildNoDashI(compiler, root, exe, workDir, objDir, deps,
                compilerFlags, depFilenames.verbose, addStubMain);
        }

        if(result.exitCode)
            return result.exitCode;

        // Touch the build witness to track the build time
        if (buildWitness !is exe)
        {
            yap("touch ", buildWitness);
            if (!dryRun)
                std.file.write(buildWitness, "");
        }
    }
  LupToDate:

    if (buildOnly)
    {
        // Pretty much done!
        return 0;
    }

    // release lock on workDir before launching the user's program
    unlockWorkPath();

    // run
    return dryRun ? 0 : exec(exe ~ programArgs);
}

size_t indexOfProgram(string[] args)
{
    foreach (i, arg; args[1 .. $])
    {
        if (!arg.startsWith('-', '@') &&
                !arg.endsWith(".obj", ".o", ".lib", ".a", ".def", ".map", ".res"))
        {
            return i + 1;
        }
    }

    return args.length;
}

void writeDeps(string exe, string root, in string[string] myDeps, File fo)
{
    fo.writeln(exe, ": \\");
    fo.write(" ", root);
    foreach (mod, _; myDeps)
    {
        fo.writeln(" \\");
        fo.write(" ", mod);
    }
    fo.writeln();
    fo.writeln();
    fo.writeln(root, ":");
    foreach (mod, _; myDeps)
    {
        fo.writeln('\n', mod, ":");
    }
}

bool ignoreModuleAsDependency(string moduleName, string filename)
{
    if (filename.endsWith(".di") || moduleName == "object" || moduleName == "gcstats")
        return true;

    foreach (string exclusion; chain(defaultExclusions, extraExclusions).filter!(ex => !includes.canFind(ex)))
        if (moduleName.startsWith(exclusion ~ '.'))
            return true;

    return false;

    // another crude heuristic: if a module's path is absolute, it's
    // considered to be compiled in a separate library. Otherwise,
    // it's a source module.
    //return isabs(mod);
}

private @property string myOwnTmpDir()
{
    auto tmpRoot = userTempDir ? userTempDir : tempDir();
    version (Posix)
    {
        import core.sys.posix.unistd;
        tmpRoot = buildPath(tmpRoot, ".rdmd-%d".format(getuid()));
    }
    else
        tmpRoot = tmpRoot.replace("/", dirSeparator).buildPath(".rdmd");

    yap("mkdirRecurse ", tmpRoot);
    if (!dryRun)
        mkdirRecurse(tmpRoot);
    return tmpRoot;
}

private string getWorkPath(in string root, string compiler, in string[] compilerFlags)
{
    static string workPath;
    if (workPath.ptr)
        return workPath;

    enum string[] irrelevantSwitches = [
        "--help", "-ignore", "-quiet", "-v" ];

    MD5 context;
    context.start();
    context.put(compiler.representation);
    context.put(root.absolutePath().representation);
    foreach (flag; compilerFlags)
    {
        if (irrelevantSwitches.canFind(flag)) continue;
        context.put(flag.representation);
    }
    foreach (f; extraFiles) context.put(f.representation);
    auto digest = context.finish();
    auto hash = toHexString(digest);

    const tmpRoot = myOwnTmpDir;
    workPath = buildPath(tmpRoot,
            "rdmd-" ~ baseName(root) ~ '-' ~ hash);

    yap("mkdirRecurse ", workPath);
    if (!dryRun)
        mkdirRecurse(workPath);

    return workPath;
}

private File lockFile;

private void lockWorkPath(string workPath)
{
    string lockFileName = buildPath(workPath, "rdmd.lock");
    if (!dryRun) lockFile.open(lockFileName, "w");
    yap("lock ", lockFile.name);
    if (!dryRun) lockFile.lock();
}

private void unlockWorkPath()
{
    yap("unlock ", lockFile.name);
    if (!dryRun)
    {
        lockFile.unlock();
        lockFile.close();
    }
}

struct BuildResult
{
    Flag!"dashIError" dashIError;
    int exitCode;
}

// Rebuild the executable fullExe starting from modules in myDeps
// passing the compiler flags compilerFlags. Generates one large
// object file.

private BuildResult rebuildWithDashI(string compiler, string root, string fullExe,
    string workDir, string objDir, string[] compilerFlags, string depsFilename,
    bool addStubMain, bool makeDepend, ref const(JsonSettings) jsonSettings)
{
    return rebuild(compiler, Yes.useDashI, root, fullExe, workDir, objDir,
        null, compilerFlags, depsFilename, addStubMain,
        makeDepend ? Yes.suppressOutput : No.suppressOutput, jsonSettings);
}
private int rebuildNoDashI(string compiler, string root, string fullExe,
    string workDir, string objDir, in string[string] deps,
    string[] compilerFlags, string depsFilename, bool addStubMain)
{
    JsonSettings noJsonSettings = void;
    auto result = rebuild(compiler, No.useDashI, root, fullExe, workDir, objDir,
        deps, compilerFlags, depsFilename, addStubMain, No.suppressOutput, noJsonSettings);
    assert(!result.dashIError);
    return result.exitCode;
}
private BuildResult rebuild(string compiler, Flag!"useDashI" useDashI, string root, string fullExe,
        string workDir, string objDir, in string[string] deps,
        string[] compilerFlags, string depsFilename, bool addStubMain,
        Flag!"suppressOutput" suppressOutput, ref const(JsonSettings) jsonSettings)
{
    version (Windows)
        fullExe = fullExe.defaultExtension(".exe");

    // Delete the old executable before we start building.
    yap("stat ", fullExe);
    if (exists(fullExe))
    {
        enforce(!isDir(fullExe), fullExe ~ " is a directory");
        yap("rm ", fullExe);
        if (!dryRun)
        {
            try
                   remove(fullExe);
            catch (FileException e)
            {
                // This can occur on Windows if the executable is locked.
                // Although we can't delete the file, we can still rename it.
                auto oldExe = "%s.%s-%s.old".format(fullExe,
                    Clock.currTime.stdTime, thisProcessID);
                yap("mv ", fullExe, " ", oldExe);
                rename(fullExe, oldExe);
            }
        }
    }

    auto fullExeTemp = fullExe ~ ".tmp";

    string[] buildTodo()
    {
        auto todo = compilerFlags
            ~ [ "-of" ~ fullExeTemp ]
            ~ [ "-od" ~ objDir ]
            ~ [ "-I" ~ dirName(root) ]
            ~ (useDashI ? [ "-i", "-Xf=" ~ depsFilename ] : null)
            ~ (suppressOutput ? [ "-o-" ] : null)
            ~ [ root ];
        if (useDashI)
        {
            foreach (exclusion; extraExclusions)
                todo ~= "-i=-" ~ exclusion;
            foreach (include; includes)
                todo ~= "-i=" ~ include;
            foreach (extraFile; extraFiles)
                todo ~= extraFile;
        }
        else
        {
            assert(deps !is null);
            foreach (k, objectFile; deps) {
                if (objectFile !is null)
                    todo ~= [ k ];
            }
        }
        // Need to add void main(){}?
        if (addStubMain)
        {
            auto stubMain = buildPath(myOwnTmpDir, "stubmain.d");
            std.file.write(stubMain, "void main(){}");
            todo ~= [ stubMain ];
        }
        return todo;
    }
    auto todo = buildTodo();

    // Different shells and OS functions have different limits,
    // but 1024 seems to be the smallest maximum outside of MS-DOS.
    enum maxLength = 1024;
    auto commandLength = escapeShellCommand(todo).length;
    if (commandLength + compiler.length >= maxLength)
    {
        auto rspName = buildPath(workDir, "rdmd.rsp");

        // DMD uses Windows-style command-line parsing in response files
        // regardless of the operating system it's running on.
        std.file.write(rspName, array(map!escapeWindowsArgument(todo)).join(" "));

        todo = [ "@" ~ rspName ];
    }

    auto fullCommand = [ compiler ] ~ todo;
    if (dryRun)
        yap("spawn ", fullCommand);
    else
    {
        Pipe stderrPipe;
        File stderrArg;
        if (useDashI)
        {
            stderrPipe = pipe();
            stderrArg = stderrPipe.writeEnd;
        }
        else
        {
            stderrArg = stderr;
        }
        auto exitCode = runProcess(fullCommand, stdin, stdout, stderrArg);
        if (exitCode)
        {
            yap("stat ", fullExeTemp);
            if (exists(fullExeTemp))
            {
               yap("remove ", fullExeTemp);
               remove(fullExeTemp);
            }
            yap("stat ", depsFilename);
            if(exists(depsFilename))
            {
                yap("remove ", depsFilename);
                remove(depsFilename);
            }
            if (useDashI)
            {
                auto firstLine = stderrPipe.readEnd.readln();
                if(firstLine.canFind("unrecognized switch '-i'"))
                {
                    return BuildResult(Yes.dashIError);
                }
                stderr.writeln(firstLine);
            }
        }
        if (useDashI)
        {
           // dump rest of stderr
           foreach (line; stderrPipe.readEnd.byLine)
           {
               stderr.writeln(line);
           }
           if (jsonSettings.enabled)
           {
               string targetJsonFile;
               if (jsonSettings.filename)
                   targetJsonFile = jsonSettings.filename;
               else
                   targetJsonFile = root.baseName.chomp(".d") ~ ".json";

               if (depsFilename != targetJsonFile)
               {
                   yap("copy ", depsFilename, " to ", targetJsonFile);
                   copy(depsFilename, targetJsonFile);
               }
           }
       }
       if (exitCode)
           return BuildResult(No.dashIError, exitCode);

       // clean up the dir containing the object file
       yap("stat ", objDir);
       if (objDir.exists && objDir.startsWith(workDir))
       {
           yap("rmdirRecurse ", objDir);
           // We swallow the exception because of a potential race: two
           // concurrently-running scripts may attempt to remove this
           // directory. One will fail.
           collectException(rmdirRecurse(objDir));
       }
       if (!suppressOutput)
       {
           yap("mv ", fullExeTemp, " ", fullExe);
           rename(fullExeTemp, fullExe);
       }
    }
    return BuildResult(No.dashIError, 0);
}

private int runProcess(T...)(string[] args, T rest)
{
    yap("spawn ", args.text);
    auto pid = spawnProcess(args, rest);
    return wait(pid);
}

// Run a program optionally writing the command line first
// If "replace" is true and the OS supports it, replace the current process.

private int run(string[] args, string output = null, bool replace = false)
{
    yap(replace ? "exec " : "spawn ", args.text);
    if (dryRun) return 0;

    if (replace && !output.ptr)
    {
        version (Windows)
            { /* Windows doesn't have exec, fall back to spawnProcess+wait */ }
        else
        {
            import std.process : execv;
            auto argv = args.map!toStringz.chain(null.only).array;
            return execv(argv[0], argv.ptr);
        }
    }

    File outputFile;
    if (output.ptr)
        outputFile = File(output, "wb");
    else
        outputFile = stdout;
    auto process = spawnProcess(args, stdin, outputFile);
    return process.wait();
}

private int exec(string[] args)
{
    return run(args, null, true);
}

private string d2obj(string objDir, string dfile)
{
    return buildPath(objDir, dfile.baseName.chomp(".d") ~ objExt);
}
private void addExtraFilesToDeps(string objDir, string[string]* deps)
{
    // All dependencies specified through --extra-file
    foreach (immutable extraFile; extraFiles)
        (*deps)[extraFile] = d2obj(objDir, extraFile);
}
private string findLib(string libName)
{
    // This can't be 100% precise without knowing exactly where the linker
    // will look for libraries (which requires, but is not limited to,
    // parsing the linker's command line (as specified in dmd.conf/sc.ini).
    // Go for best-effort instead.
    string[] dirs = ["."];
    foreach (envVar; ["LIB", "LIBRARY_PATH", "LD_LIBRARY_PATH"])
        dirs ~= environment.get(envVar, "").split(pathSeparator);
    version (Windows)
        string[] names = [libName ~ ".lib"];
    else
    {
        string[] names = ["lib" ~ libName ~ ".a", "lib" ~ libName ~ ".so"];
        dirs ~= ["/lib", "/usr/lib"];
    }
    foreach (dir; dirs)
        foreach (name; names)
        {
            auto path = buildPath(dir, name);
            if (path.exists)
                return absolutePath(path);
        }
    return null;
}

// Assumption: depsFilename exists
string[string] readJsonDepsFile(string objDir, string depsFilename)
{
    import std.json : parseJSON, JSONValue;

    yap("read ", depsFilename);
    auto jsonText = readText(depsFilename);
    auto json = parseJSON(jsonText);
    string[string] result;
    bool foundBuildInfo, foundSemantics;
    foreach (element; json.array())
    {
        if(element["kind"].str == "buildInfo")
        {
            assert(!foundBuildInfo);
            foundBuildInfo = true;
            result[element["binary"].str] = null;
            {
                auto configProperty = element.object.get("config", JSONValue.init);
                if (!configProperty.isNull)
                {
                    result[configProperty.str] = null;
                }
            }
            {
                auto libraryProperty = element.object.get("library", JSONValue.init);
                if (!libraryProperty.isNull)
                {
                    auto libPath = findLib(libraryProperty.str);
                    yap("library ", libraryProperty, " ", libPath);
                    result[libPath] = null;
                }
            }
        }
        else if(element["kind"].str == "semantics")
        {
            assert(!foundSemantics);
            foundSemantics = true;
            foreach (module_; element["modules"].array)
            {
                {
                    auto contentImports = module_.object.get("contentImports", JSONValue.init);
                    if (!contentImports.isNull)
                    {
                        foreach (contentImport; contentImports.array)
                        {
                            result[contentImport.str] = null;
                        }
                    }
                }
                {
                    auto filename = module_["file"].str;
                    auto nameNode = module_.object.get("name", JSONValue.init);
                    bool ignoreAsDependency = false;
                    if (!nameNode.isNull)
                    {
                        ignoreAsDependency = ignoreModuleAsDependency(nameNode.str, filename);
                    }
                    if (!ignoreAsDependency)
                        result[filename] = d2obj(objDir, filename);
                }
            }
        }
        else
        {
            // ignore the rest of the JSON
        }
    }
    assert(foundBuildInfo && foundSemantics);
    addExtraFilesToDeps(objDir, &result);
    return result;
}
string[string] readVerboseDepsFile(string objDir, string depsFilename)
{
    yap("read ", depsFilename);
    auto depsReader = File(depsFilename);
    scope(exit) collectException(depsReader.close()); // don't care for errors

    // Fetch all dependencies and append them to myDeps
    auto pattern = ctRegex!(r"^(import|file|binary|config|library)\s+([^\(]+)\(?([^\)]*)\)?\s*$");
    string[string] result;
    foreach (string line; lines(depsReader))
    {
        auto regexMatch = match(line, pattern);
        if (regexMatch.empty) continue;
        auto captures = regexMatch.captures;
        switch(captures[1])
        {
        case "import":
            immutable moduleName = captures[2].strip(), moduleSrc = captures[3].strip();
            if (ignoreModuleAsDependency(moduleName, moduleSrc)) continue;
            immutable moduleObj = d2obj(objDir, moduleSrc);
            result[moduleSrc] = moduleObj;
            break;

        case "file":
            result[captures[3].strip()] = null;
            break;

        case "binary":
            result[which(captures[2].strip())] = null;
            break;

        case "config":
            auto confFile = captures[2].strip;
            // The config file is special: if missing, that's fine too. So
            // add it as a dependency only if it actually exists.
            yap("stat ", confFile);
            if (confFile.exists)
            {
                result[confFile] = null;
            }
            break;

        case "library":
            immutable libName = captures[2].strip();
            immutable libPath = findLib(libName);
            if (libPath.ptr)
            {
                yap("library ", libName, " ", libPath);
                result[libPath] = null;
            }
            break;

        default: assert(0);
        }
    }
    addExtraFilesToDeps(objDir, &result);
    return result;
}

struct DepFilenames
{
    string verbose;
    string json;
}
struct JsonSettings
{
    bool enabled;
    string filename;
}

// Given module rootModule, returns a mapping of all dependees .d
// source filenames to their corresponding .o files sitting in
// directory workDir. The mapping is obtained by running dmd -v against
// rootModule.

private string[string] tryGetDepsFromFile(string rootModule,
        string objDir, string[] compilerFlags, DepFilenames depFilenames)
{
    // Check JSON file first
    yap("stat ", depFilenames.json);
    auto jsonDepsTime = depFilenames.json.timeLastModified(SysTime.min);
    if (jsonDepsTime != SysTime.min)
    {
        auto deps = readJsonDepsFile(objDir, depFilenames.json);
        yap("read deps file: ", depFilenames.json);
        if (deps.byKey.anyNewerThan(jsonDepsTime))
        {
            yap("deps file is out-of-date");
            return null; // need to rebuild, deps are out of date
        }
        return deps;
    }

    // TODO: small optimization
    // if verbose file is present but JSON isn't, then we know that -i is not supported

    // Check VERBOSE file next
    yap("stat ", depFilenames.verbose);
    auto verboseDepsTime = depFilenames.verbose.timeLastModified(SysTime.min);
    if (verboseDepsTime != SysTime.min)
    {
        auto deps = readVerboseDepsFile(objDir, depFilenames.verbose);
        yap("read deps file: ", depFilenames.verbose);
        if (chain(rootModule.only, deps.byKey).anyNewerThan(verboseDepsTime))
        {
            yap("deps file is out-of-date");
            return null; // need to rebuild, deps are out of date
        }
        return deps;
    }

    yap("there is no deps file");
    return null; // there are no dependency files
}

// this method is only here to support legacy compiler's that don't
// support the "-i" method, which enables both compiling and getting
// dependencies in a single call to the compiler.
private string[string] getDepsUsingCompiler(string compiler, string rootModule,
    string objDir, string[] compilerFlags, string depsFilename)
{
    immutable rootDir = dirName(rootModule);

    // Filter out -lib. With -o-, it will create an empty library file.
    compilerFlags = compilerFlags.filter!(flag => flag != "-lib").array();

    // Collect dependencies
    auto depsGetter =
        // "cd " ~ shellQuote(rootDir) ~ " && "
        [ compiler ] ~ compilerFlags ~
        ["-v", "-o-", rootModule, "-I" ~ rootDir];

    scope(failure)
    {
        // Delete the deps file on failure, we don't want to be fooled
        // by it next time we try
        collectException(std.file.remove(depsFilename));
    }

    File depsFile = File(depsFilename, "wb");
    auto exitCode = runProcess(depsGetter, stdin, depsFile);
    if (exitCode)
    {
        stderr.writefln("Failed: %s", depsGetter);
        collectException(std.file.remove(depsFilename));
        exit(exitCode);
    }

    return readVerboseDepsFile(objDir, depsFilename);
}

// Is any file newer than the given file?
bool anyNewerThan(T)(T files, in string file)
{
    yap("stat ", file);
    return files.anyNewerThan(file.timeLastModified);
}

// Is any file newer than the given file?
bool anyNewerThan(T)(T files, SysTime t)
{
    bool result;
    foreach (source; taskPool.parallel(files))
    {
        yap("stat ", source);
        if (!result && source.newerThan(t))
        {
            result = true;
        }
    }
    return result;
}

/*
If force is true, returns true. Otherwise, if source and target both
exist, returns true iff source's timeLastModified is strictly greater
than target's. Otherwise, returns true.
 */
private bool newerThan(string source, string target)
{
    if (force) return true;
    yap("stat ", target);
    return source.newerThan(target.timeLastModified(SysTime.min));
}

private bool newerThan(string source, SysTime target)
{
    if (force) return true;
    try
    {
        yap("stat ", source);
        return DirEntry(source).timeLastModified > target;
    }
    catch (Exception)
    {
        // File not there, consider it newer
        return true;
    }
}

private @property string helpString()
{
    return
"rdmd build " ~ thisVersion ~ "
Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]...
Builds (with dependents) and runs a D program.
Example: rdmd -release myprog --myprogparm 5

Any option to be passed to the compiler must occur before the program name. In
addition to compiler options, rdmd recognizes the following options:
  --build-only       just build the executable, don't run it
  --chatty           write compiler commands to stdout before executing them
  --compiler=comp    use the specified compiler (e.g. gdmd) instead of %s
  --dry-run          do not compile, just show what commands would be run
                      (implies --chatty)
  --eval=code        evaluate code as in perl -e (multiple --eval allowed)
  --exclude=package  exclude a package from the build (multiple --exclude allowed)
  --include=package  negate --exclude or a standard package (%-(%s, %))
  --extra-file=file  include an extra source or object in the compilation
                     (multiple --extra-file allowed)
  --force            force a rebuild even if apparently not necessary
  --help             this message
  --loop             assume \"foreach (line; stdin.byLine()) { ... }\" for eval
  --main             add a stub main program to the mix (e.g. for unittesting)
  --makedepend       print dependencies in makefile format and exit
                     (needs dmd's option `-of` to be present)
  --makedepfile=file print dependencies in makefile format to file and continue
                     (needs dmd's option `-of` to be present)
  --man              open web browser on manual page
  --shebang          rdmd is in a shebang line (put as first argument)
  --tmpdir           set an alternative temporary directory
".format(defaultCompiler, defaultExclusions);
}

// For --eval and --loop
immutable string importWorld = "
module temporary;
import std.stdio, std.algorithm, std.array, std.ascii, std.base64,
    std.bigint, std.bitmanip,
    std.compiler, std.complex, std.concurrency, std.container, std.conv,
    std.csv,
    std.datetime, std.demangle, std.digest.md, std.encoding, std.exception,
    std.file,
    std.format, std.functional, std.getopt, std.json,
    std.math, std.mathspecial, std.mmfile,
    std.numeric, std.outbuffer, std.parallelism, std.path, std.process,
    std.random, std.range, std.regex, std.signals, std.socket,
    std.stdint, std.stdio,
    std.string, std.windows.syserror, std.system, std.traits, std.typecons,
    std.typetuple, std.uni, std.uri, std.utf, std.variant, std.xml, std.zip,
    std.zlib;
";

string makeEvalFile(string todo)
{
    auto pathname = myOwnTmpDir;
    auto srcfile = buildPath(pathname,
            "eval." ~ todo.md5Of.toHexString ~ ".d");

    if (force || !exists(srcfile))
    {
        std.file.write(srcfile, todo);
    }

    // Clean pathname
    enum lifetimeInHours = 24;
    auto cutoff = Clock.currTime() - dur!"hours"(lifetimeInHours);
    yap("dirEntries ", pathname);
    foreach (DirEntry d; dirEntries(pathname, SpanMode.shallow))
    {
        yap("stat ", d.name);
        if (d.timeLastModified < cutoff)
        {
            collectException(std.file.remove(d.name));
            //break; // only one per call so we don't waste time
        }
    }

    return srcfile;
}

@property string thisVersion()
{
    enum d = __DATE__;
    enum month = d[0 .. 3],
        day = d[4] == ' ' ? "0" ~ d[5] : d[4 .. 6],
        year = d[7 .. $];
    enum monthNum
        = month == "Jan" ? "01"
        : month == "Feb" ? "02"
        : month == "Mar" ? "03"
        : month == "Apr" ? "04"
        : month == "May" ? "05"
        : month == "Jun" ? "06"
        : month == "Jul" ? "07"
        : month == "Aug" ? "08"
        : month == "Sep" ? "09"
        : month == "Oct" ? "10"
        : month == "Nov" ? "11"
        : month == "Dec" ? "12"
        : "";
    static assert(month != "", "Unknown month " ~ month);
    return year[0] ~ year[1 .. $] ~ monthNum ~ day;
}

string which(string path)
{
    yap("which ", path);
    if (path.canFind(dirSeparator) || altDirSeparator != "" && path.canFind(altDirSeparator)) return path;
    string[] extensions = [""];
    version(Windows) extensions ~= environment["PATHEXT"].split(pathSeparator);
    foreach (envPath; environment["PATH"].splitter(pathSeparator))
    {
        foreach (extension; extensions)
        {
            string absPath = buildPath(envPath, path ~ extension);
            yap("stat ", absPath);
            if (exists(absPath) && isFile(absPath))
                return absPath;
        }
    }
    throw new FileException(path, "File not found in PATH");
}

void yap(size_t line = __LINE__, T...)(auto ref T stuff)
{
    if (!chatty) return;
    debug stderr.writeln(line, ": ", stuff);
    else stderr.writeln(stuff);
}

struct CompilerInfo
{
    Flag!"supportsDashI" supportsDashI;
    Flag!"useJsonDeps" useJsonDeps;
}
auto getCompilerInfo(string jsonDepFilename, string compiler)
{
    if (exists(jsonDepFilename)
    auto helpPipe = pipe();
    auto compilerName = baseName(compiler);
    if (compilerName == "dmd")
    {
        auto exitCode = runProcess([compiler, "--version"], stdin, helpPipe.writeEnd);
        auto firstLine = helpPipe.readEnd.readln().strip();
        yap("compiler version line: ", firstLine);
        string versionString;
        {
            auto start = firstLine.indexOf(" v2");
            assert(start >= 0);
            versionString = firstLine[start + 1 .. $];
        }
        auto version_ = parseDmdVersion(versionString);
        return CompilerInfo(
            (version_.major >= 2 && version_.major >= 79) ? Yes.supportsDashI : No.supportsDashI);
    }
    else if (compilerName == "ldmd2")
    {
        return CompilerInfo(No.supportsDashI);
    }
    else if (compilerName == "gdmd")
    {
        return CompilerInfo(No.supportsDashI);
    }
    else
    {
        return CompilerInfo(No.supportsDashI);
    }
}

struct DmdVersion
{
   ushort major;
   ushort minor;
}
DmdVersion parseDmdVersion(const(char)[] versionString)
{
    yap("DMD version string: ", versionString);
    assert(versionString[0] == 'v');
    versionString = versionString[1 .. $];

    auto components = splitter(versionString, '.');
    assert(!components.empty());

    auto version_ = DmdVersion();
    static import std.conv;
    version_.major = std.conv.to!ushort(components.front);
    components.popFront();
    assert(!components.empty());
    version_.minor = std.conv.to!ushort(components.front);
    yap("DMD version major=", version_.major, " minor=", version_.minor);
    return version_;
}
