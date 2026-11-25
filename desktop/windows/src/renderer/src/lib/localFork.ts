// LOCAL ADAPT: the 小蜗 build removes Omi's Hub connectors, coding agents, plans /
// usage limits, and referral/Discord links. Vitest runs with MODE === 'test', so the
// upstream suites keep exercising the upstream behavior they were written against.
export const LOCAL_FORK = import.meta.env.MODE !== 'test'
