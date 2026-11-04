import type { APIRoute } from 'astro';
import { publishedPosts, sitePath, type BlogPost } from '../../lib/blog';
import { researchSitePath } from '../../../research-links.mjs';

export async function getStaticPaths() {
	return (await publishedPosts()).map((post) => ({ params: { slug: post.id }, props: { post } }));
}

export const GET: APIRoute = ({ props, site }) => {
	const post = props.post as BlogPost;
	// Use absolute links in this portable version, without changing code examples.
	const body = (post.body ?? '').split(/(^```[^\n]*\n[\s\S]*?^```)/gm)
		.map((part, i) => i % 2 ? part : part.replace(/\]\((\/(?!\/)[^\s)]+)\)/g,
			(_, path) => `](${researchSitePath(path) ?? new URL(sitePath(path), site).href})`)).join('');
	return new Response(`# ${post.data.title}\n\n${post.data.author} · ${post.data.date.toISOString().slice(0, 10)}\n\n${body}`, {
		headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
	});
};
