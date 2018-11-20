import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.typecons;

import ae.utils.aa : toSet;
import ae.utils.array : skipUntil, shift;

string[] compiler;

void main(string[] args)
{
	compiler = [environment.get("DMD", "dmd")];
	string[] compilerOpts, compilerFiles;
	args = args[1..$];
	while (args.length && args[0].startsWith('-'))
		compilerOpts ~= args.shift;
	compilerFiles = args;

	stderr.writeln("dmdforker: Collecting dependencies...");
	auto fDeps = getDeps(compilerOpts, compilerFiles);
	auto cDeps = splitComponents(fDeps);

	auto compiledFiles = fDeps.compiled.byKey.map!(fileIndex => fDeps.fileNames[fileIndex]).toSet;
	foreach (fn; compilerFiles)
		compiledFiles.add(fn
			.absolutePath()
			.buildNormalizedPath()
			.defaultExtension(".d"));

	stderr.writeln("dmdforker: Starting DMD fork server.");
	if (!compilerOpts.canFind!(opt => opt.startsWith("-of")))
		compilerOpts ~= "-of" ~ compilerFiles.front.stripExtension;
	auto commRead = std.process.pipe();
	uninherit(commRead.writeEnd);
	auto commWrite = std.process.pipe();
	uninherit(commWrite.readEnd);
	auto compilerArgs = compiler ~ compilerOpts ~ [
		"-fork-server",
		commRead.readEnd.fileno.text,
		commWrite.writeEnd.fileno.text,
	];
	auto pid = spawnProcess(compilerArgs, null, Config.inheritFDs);
	enforce(getchar(commWrite.readEnd) == 'K', "Unexpected reply from fork server");
	stderr.writeln("dmdforker: Fork server ready, performing initial compilation.");
	commRead.writeEnd.setvbuf(0, _IONBF);

	Component[] oldComponents;
	while (true)
	{
		auto sw = StopWatch(AutoStart.yes);

		auto components = sortComponents(cDeps);

		auto commonPrefix = commonPrefix(oldComponents, components);
		auto numReused = commonPrefix.length;
		stderr.writefln("dmdforker: Reusing %d/%d components.", numReused, components.length);
		if (commonPrefix.length != oldComponents.length)
		{
			commRead.writeEnd.writeln('R', commonPrefix.length); // Rewind!
			enforce(getchar(commWrite.readEnd) == 'K', "Unexpected reply from fork server");
			oldComponents = commonPrefix;
		}

		bool ok = true;

		foreach (i, component; components[commonPrefix.length .. $])
		{
			stderr.writefln("dmdforker: [%s%s>%s]", repeat('C', numReused), repeat('#', i), repeat('.', components.length - numReused - i - 1));
			commRead.writeEnd.write('G'); // Compile group
			foreach (fileName; component.fileNames.filter!(fn => fn in compiledFiles))
				commRead.writeEnd.writeln(fileName);
			commRead.writeEnd.writeln(); // End of file names
			switch (getchar(commWrite.readEnd))
			{
				case 'K': // OK
					oldComponents ~= component;
					continue;
				case 'E': // Error
					ok = false;
					break;
				default:
					throw new Exception("Bad result from fork-server");
			}
		}

		if (ok)
		{
			// Finish compilation
			stderr.writefln("dmdforker: Finalizing.");
			commRead.writeEnd.write('F');
			enforce(getchar(commWrite.readEnd) == 'K', "Unexpected reply from fork server");
		}

		stderr.writefln("dmdforker: Done in %s, press Enter to recompile...", sw.peek());
		readln();
	}
}

void uninherit(File file)
{
	import core.sys.posix.fcntl;

	int fileno = file.fileno();
	int fdflags = fcntl(fileno, F_GETFD);
	fcntl(fileno, F_SETFD, fdflags & ~FD_CLOEXEC);
}
char getchar(File f)
{
	char[1] buf;
	auto res = f.rawRead(buf);
	enforce(res.length == buf.length, "End of file");
	return buf[0];
}

struct FileDeps
{
	string[] fileNames;
	bool[size_t] compiled;
	bool[size_t][size_t] deps; // graph
}

FileDeps getDeps(string[] compilerOpts, string[] compilerFiles)
{
	FileDeps deps;
	size_t[string] lookup;
	size_t getFileIndex(string fn)
	{
		fn = fn.absolutePath().buildNormalizedPath();
		auto p = fn in lookup;
		if (p) return *p;
		deps.fileNames ~= fn;
		return lookup[fn] = deps.fileNames.length - 1;
	}

	auto result = execute(compiler ~ compilerOpts ~ ["-deps", "-v", "-o-", "-i"] ~ compilerFiles, null, Config.stderrPassThrough);
	enforce(result.status == 0, "Could not acquire full dependency graph due to compilation failure");
	foreach (line; result.output.splitLines)
	{
		auto oline = line;
		if (line.skipOver("depsImport "))
		{
			line.skipUntil(" (")              .enforce("Bad depsImport line: " ~ oline);
			auto from = line.skipUntil(") : ").enforce("Bad depsImport line: " ~ oline);
			line.skipUntil(" (")              .enforce("Bad depsImport line: " ~ oline);
			auto to = line.skipUntil(")")     .enforce("Bad depsImport line: " ~ oline);
			deps.deps[getFileIndex(from)][getFileIndex(to)] = true;
		}
		else
		if (line.skipOver("compileimport ("))
		{
			auto fn = line.skipUntil(")")     .enforce("Bad depsImport line: " ~ oline);
			deps.compiled[getFileIndex(fn)] = true;
		}
	}
	return deps;
}

struct ComponentDeps
{
	string[][] fileNames;
	bool[size_t][size_t] deps; // DAG
}

ComponentDeps splitComponents(FileDeps files)
{
	// Use Kosaraju's algorithm to find strongly-connected components

	auto numFiles = files.fileNames.length;
	auto visited = new bool[numFiles];
	size_t[] stack;

	void visit(size_t fileIndex)
	{
		if (visited[fileIndex])
			return;
		visited[fileIndex] = true;
		files.deps.get(fileIndex, null).byKey.each!visit;
		stack ~= fileIndex;
	}

	foreach (fileIndex; 0 .. numFiles)
		visit(fileIndex);

	// Transpose graph
	bool[size_t][size_t] transposedDeps;
	foreach (fileIndex, fileDeps; files.deps)
		foreach (outNeighbor; fileDeps.byKey)
			transposedDeps[outNeighbor][fileIndex] = true;

	auto fileComponents = new size_t[numFiles];
	fileComponents[] = size_t.max;

	void assign(size_t fileIndex, size_t componentIndex)
	{
		if (fileComponents[fileIndex] != size_t.max)
			return;
		fileComponents[fileIndex] = componentIndex;
		foreach (inNeighbor; transposedDeps.get(fileIndex, null).byKey)
			assign(inNeighbor, componentIndex);
	}

	size_t numComponents;
	foreach_reverse (fileIndex; stack)
		if (fileComponents[fileIndex] == size_t.max)
			assign(fileIndex, numComponents++);

	// Populate resulting component DAG
	ComponentDeps components;
	components.fileNames.length = numComponents;
	foreach (fileIndex; 0 .. numFiles)
	{
		auto componentIndex = fileComponents[fileIndex];
		components.fileNames[componentIndex] ~= files.fileNames[fileIndex];
		foreach (outNeighbor; files.deps.get(fileIndex, null).byKey)
		{
			auto neighborComponentIndex = fileComponents[outNeighbor];
			if (componentIndex != neighborComponentIndex)
				components.deps[componentIndex][neighborComponentIndex] = true;
		}
	}

	return components;
}

struct Component
{
	string[] fileNames;
	SysTime mTime;
}

/// Sort components topologically, and then by modification time
Component[] sortComponents(ComponentDeps components)
{
	auto numComponents = components.fileNames.length;

	// Get the modification times.
	// For each component, we care about the
	// newest-modified file within the group.
	auto mTimes = components.fileNames.map!(
		component => component.map!timeLastModified.reduce!max
	).array;

	// Perform a topological+chronological insertion sort
	size_t[] order;
	foreach (n; 0 .. numComponents)
	{
		auto pos = 0;
		// Move as far as possible, but not beyond a parent.
		while (pos < order.length && !components.deps.get(order[pos], null).get(n, false))
			pos++;
		// Move back according to timestamp, but not beyond a child
		while (pos && mTimes[n] < mTimes[order[pos-1]] && !components.deps.get(n, null).get(order[pos-1], false))
			pos--;
		order.insertInPlace(pos, n);
	}

	return order.map!(componentIndex => Component(components.fileNames[componentIndex], mTimes[componentIndex])).array;
}
