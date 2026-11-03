import { getCollection, type CollectionEntry } from 'astro:content';

export type BlogPost = CollectionEntry<'blog'>;

export async function publishedPosts() {
	return (await getCollection('blog', ({ data }) => !data.draft))
		.sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf() || a.id.localeCompare(b.id));
}

export function sitePath(path = '') {
	return import.meta.env.BASE_URL.replace(/\/?$/, '/') + path.replace(/^\//, '');
}

export function readingMinutes(post: BlogPost) {
	const words = (post.body ?? '').replace(/^```[\s\S]*?^```/gm, '').trim().split(/\s+/).length;
	return Math.max(1, Math.ceil(words / 220));
}

export function formatDate(date: Date) {
	return new Intl.DateTimeFormat('en-GB', {
		day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC',
	}).format(date);
}

export function escapeXml(value: string) {
	return value.replace(/[<>&"']/g, (char) => ({
		'<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;',
	})[char]!);
}
