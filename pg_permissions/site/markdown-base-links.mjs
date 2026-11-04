import { researchSitePath } from './research-links.mjs';

// Site-relative Markdown links also work when the site is hosted below a path.
// Links to the old /research/ paths go to the research site.
export default function baseLinks({ base = '' } = {}) {
	const prefix = base.replace(/\/$/, '');
	const rewrite = (node, ctx) => {
		const research = researchSitePath(node.url);
		if (research) ctx.setProperty(node, 'url', research);
		else if (/^\/(?!\/)/.test(node.url)) ctx.setProperty(node, 'url', prefix + node.url);
	};
	return { name: 'site-base-links', link: rewrite, definition: rewrite, image: rewrite };
}
