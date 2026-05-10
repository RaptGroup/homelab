// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://jvcorredor.github.io',
  base: '/homelab',
  integrations: [
    starlight({
      title: 'Rockingham Homelab',
      description:
        'Documentation for the Rockingham Homelab: a 6-node bare-metal Kubernetes cluster running Talos Linux.',
      social: {
        github: 'https://github.com/jvcorredor/homelab',
      },
      editLink: {
        baseUrl: 'https://github.com/jvcorredor/homelab/edit/main/docs/',
      },
      lastUpdated: true,
      sidebar: [
        {
          label: 'Start here',
          items: [
            { slug: 'index' },
            { slug: 'overview/architecture' },
          ],
        },
        {
          label: 'Architecture',
          autogenerate: { directory: 'architecture' },
        },
        {
          label: 'Networking',
          autogenerate: { directory: 'networking' },
        },
      ],
    }),
  ],
});
