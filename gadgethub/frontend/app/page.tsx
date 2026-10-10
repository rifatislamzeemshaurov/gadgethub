import GadgetHubAdvisor from '@/components/gadgethub-advisor';

export default function Home() {
  return (
    <main className="h-app relative flex w-full flex-col overflow-hidden bg-slate-950">
      {/* Ambient backdrop */}
      <div className="bg-grid pointer-events-none absolute inset-0" />
      <div className="pointer-events-none absolute -top-32 left-1/2 h-72 w-[36rem] -translate-x-1/2 rounded-full bg-indigo-600/20 blur-3xl" />
      <div className="pointer-events-none absolute -bottom-40 -right-24 h-72 w-72 rounded-full bg-sky-500/10 blur-3xl" />
      <div className="pointer-events-none absolute -bottom-40 -left-24 h-72 w-72 rounded-full bg-violet-600/10 blur-3xl" />

      <div className="relative z-10 flex min-h-0 flex-1 flex-col">
        <GadgetHubAdvisor />
      </div>
    </main>
  );
}
