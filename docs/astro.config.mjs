// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://raptgroup.github.io',
  base: '/homelab',
  integrations: [
    starlight({
      title: 'Rockingham Homelab',
      description:
        'Documentation for the Rockingham Homelab: a 6-node bare-metal Kubernetes cluster running Talos Linux.',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/RaptGroup/homelab',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/RaptGroup/homelab/edit/main/docs/',
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
          items: [{ autogenerate: { directory: 'architecture' } }],
        },
        {
          label: 'Networking',
          items: [{ autogenerate: { directory: 'networking' } }],
        },
        {
          label: 'Cloud',
          items: [{ autogenerate: { directory: 'cloud' } }],
        },
        {
          label: 'Platform',
          items: [{ autogenerate: { directory: 'platform' } }],
        },
        {
          label: 'Applications',
          items: [{ autogenerate: { directory: 'applications' } }],
        },
        {
          label: 'Automation',
          items: [{ autogenerate: { directory: 'automation' } }],
        },
      ],
    }),
  ],
});
