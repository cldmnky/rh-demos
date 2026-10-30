import { Label, Skeleton } from '@patternfly/react-core';
import { CubeIcon, DatabaseIcon, ServerIcon } from '@patternfly/react-icons';
import { Stats, WebInfo, dbVersionLabel } from '../api';

/**
 * One badge per tier. VM and container are the only two answers, and the badge
 * flips live during the cutover while MariaDB keeps serving the same rows.
 */
export const RuntimeLabel = ({ runtime }: { runtime: string | undefined }) => {
  if (!runtime) {
    return <Skeleton width="64px" screenreaderText="Waiting for runtime" />;
  }
  const isContainer = runtime.toLowerCase() !== 'vm';
  return (
    <Label
      color={isContainer ? 'green' : 'blue'}
      icon={isContainer ? <CubeIcon /> : <ServerIcon />}
      isCompact
      data-testid={`runtime-${isContainer ? 'container' : 'vm'}`}
    >
      {runtime}
    </Label>
  );
};

export const DbLabel = ({ stats }: { stats: Stats | null }) =>
  stats ? (
    <Label color="purple" icon={<DatabaseIcon />} isCompact>
      {dbVersionLabel(stats.db.version)}
    </Label>
  ) : (
    <Skeleton width="120px" screenreaderText="Waiting for MariaDB" />
  );

/** Masthead strip: always on screen, in every segment of the demo. */
export function StackBadges({ web, stats }: { web: WebInfo | null; stats: Stats | null }) {
  return (
    <div className="rr-badges">
      <span className="rr-badges__tier">
        web
        <span data-testid="web-runtime">
          <RuntimeLabel runtime={web?.runtime} />
        </span>
      </span>
      <span className="rr-badges__tier">
        api
        <span data-testid="api-runtime">
          <RuntimeLabel runtime={stats?.runtime} />
        </span>
      </span>
      <span className="rr-badges__tier">
        db
        <span data-testid="db-version">
          <DbLabel stats={stats} />
        </span>
      </span>
    </div>
  );
}
