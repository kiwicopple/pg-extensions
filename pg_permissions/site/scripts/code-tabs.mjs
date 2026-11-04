// Adjacent tagged code fences form a language switcher. Source order also
// controls the Markdown export and Starlight's default tab on a first visit.
export function convertTabs(body, srcFile) {
	const lines = body.split('\n');
	// 1. find the fenced blocks
	const blocks = [];
	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^(\s*)(`{3,}|~{3,})\s*(\S*)\s*(.*?)\s*$/);
		if (!m) continue;
		let end = -1;
		for (let j = i + 1; j < lines.length; j++) {
			const c = lines[j].match(/^\s*(`{3,}|~{3,})\s*$/);
			if (c && c[1][0] === m[2][0] && c[1].length >= m[2].length) {
				end = j;
				break;
			}
		}
		if (end < 0) break; // unclosed fence: leave the rest alone
		const tab = m[4].match(/\btab="([^"]*)"/);
		blocks.push({
			start: i,
			end,
			indent: m[1],
			fence: m[2],
			lang: m[3],
			meta: m[4].replace(/\btab="[^"]*"/, '').trim(),
			tab: tab ? tab[1] : null,
		});
		i = end;
	}
	// 2. group adjacent tab blocks
	const groups = [];
	let cur = [];
	const flush = () => {
		if (cur.length) groups.push(cur);
		cur = [];
	};
	for (const b of blocks) {
		if (b.tab === null) {
			flush();
			continue;
		}
		const prev = cur[cur.length - 1];
		const gap = prev ? lines.slice(prev.end + 1, b.start) : [];
		if (prev && !gap.every((l) => l.trim() === '')) flush();
		cur.push(b);
	}
	flush();
	// 3. rewrite, from the end so that the indexes stay valid
	let n = 0;
	for (const g of groups.reverse()) {
		const fenceLine = (b) => `${b.indent}${b.fence}${b.lang}${b.meta ? ' ' + b.meta : ''}`;
		const labels = g.map((block) => block.tab);
		const location = srcFile + ':' + (g[0].start + 1);
		if (g.length < 2) throw new Error(location + ': a tagged example needs at least two adjacent language blocks');
		if (labels.some((label) => !/^[A-Za-z0-9.#][A-Za-z0-9 .+#-]*$/.test(label) || label !== label.trim())) {
			throw new Error(location + ': use a plain language name for each tab label');
		}
		if (new Set(labels).size !== labels.length) throw new Error(location + ': repeated tab label in one example');
		if (labels.includes('JavaScript') && labels[0] !== 'JavaScript') throw new Error(location + ': put the JavaScript block first');
		if (labels.includes('SQL') && labels.at(-1) !== 'SQL') throw new Error(location + ': put the SQL block last');
		const out = ['<Tabs syncKey="lang">'];
		g.forEach((b, k) => {
			out.push(`<TabItem label="${b.tab}">`, '', fenceLine(b), ...lines.slice(b.start + 1, b.end + 1), '', '</TabItem>');
			if (k === g.length - 1) out.push('</Tabs>');
		});
		lines.splice(g[0].start, g[g.length - 1].end - g[0].start + 1, ...out);
		n++;
	}
	return { body: lines.join('\n'), groups: n };
}
