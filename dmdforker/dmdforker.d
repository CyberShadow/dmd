import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
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
	auto components = sortComponents(cDeps);

	auto compiledFiles = fDeps.compiled.byKey.map!(fileIndex => fDeps.fileNames[fileIndex]).toSet;
	foreach (fn; compilerFiles)
		compiledFiles.add(fn
			.absolutePath()
			.buildNormalizedPath()
			.defaultExtension(".d"));

	auto compiledGroups = components.map!(fileNames => fileNames.filter!(fn => fn in compiledFiles).array).array;
	//compiledGroups.each!writeln;

	stderr.writeln("dmdforker: Starting DMD fork server.");
	auto comm = std.process.pipe();
	auto compilerArgs = compiler ~ compilerOpts ~ ["-fork-server"] ~ compiledGroups.join(["-fork-delim"]);
	stderr.writeln(escapeShellCommand(compilerArgs));
	auto pid = spawnProcess(compilerArgs, comm.readEnd);
	pid.wait();
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

/// Sort components topologically, and then by modification time
string[][] sortComponents(ComponentDeps components)
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

	return order.map!(componentIndex => components.fileNames[componentIndex]).array;
}
