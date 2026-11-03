import type { APIRoute } from 'astro';
import { publishedPosts, sitePath, escapeXml } from '../../lib/blog';

export const GET: APIRoute = async ({ site }) => {
	const url = (path: string) => escapeXml(new URL(sitePath(path), site).href);
	const posts = await publishedPosts();
	const items = posts.map((post) => `<item>
		<title>${escapeXml(post.data.title)}</title>
		<link>${url(`blog/${post.id}/`)}</link>
		<guid isPermaLink="true">${url(`blog/${post.id}/`)}</guid>
		<description>${escapeXml(post.data.description)}</description>
		<pubDate>${post.data.date.toUTCString()}</pubDate>
	</item>`).join('\n');
	return new Response(`<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel>
	<title>pg_permissions blog</title>
	<link>${url('blog/')}</link>
	<description>Experiments, decisions and release notes from building authorization inside Postgres.</description>
	<language>en</language>
	<atom:link href="${url('blog/rss.xml')}" rel="self" type="application/rss+xml" />
	${items}
</channel></rss>`, { headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' } });
};
