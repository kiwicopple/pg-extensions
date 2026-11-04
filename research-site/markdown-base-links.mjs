// Site-relative Markdown links also work when the site is hosted below a path.
export default function baseLinks({ base = '' } = {}) {
	const prefix = base.replace(/\/$/, '');
	const rewrite = (node, ctx) => {
		if (/^\/(?!\/)/.test(node.url)) ctx.setProperty(node, 'url', prefix + node.url);
	};
	return { name: 'site-base-links', link: rewrite, definition: rewrite, image: rewrite };
}
