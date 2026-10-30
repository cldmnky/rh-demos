import {
  Card,
  CardBody,
  CardHeader,
  CardTitle,
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Flex,
  FlexItem,
  Icon,
  Label,
  Skeleton,
} from '@patternfly/react-core';
import { CloudServerIcon, DatabaseIcon } from '@patternfly/react-icons';
import { Stats, WebInfo, dbVersionLabel } from '../api';
import { RuntimeLabel } from './StackBadges';

const uptime = (seconds: number) => {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
};

/**
 * The stack badge: the one panel that must stay on screen through the cutover.
 * Web and API runtimes flip from VM to container while MariaDB keeps the data.
 */
export function StackCard({ web, stats }: { web: WebInfo | null; stats: Stats | null }) {
  return (
    <Card className="rr-card rr-stack">
      <CardHeader>
        <CardTitle>
          <Flex spaceItems={{ default: 'spaceItemsSm' }} alignItems={{ default: 'alignItemsCenter' }}>
            <FlexItem>
              <Icon size="lg">
                <CloudServerIcon />
              </Icon>
            </FlexItem>
            <FlexItem>Where this page runs</FlexItem>
          </Flex>
        </CardTitle>
      </CardHeader>
      <CardBody>
        <DescriptionList isCompact>
          <DescriptionListGroup>
            <DescriptionListTerm>Web tier</DescriptionListTerm>
            <DescriptionListDescription>
              <div>{RuntimeLabel({ runtime: web?.runtime })}</div>
              <div className="rr-placement">
                <span>{web ? `${web.name || "—"} · namespace ${web.namespace || "—"} · node ${web.node || "—"}` : 'loading…'}</span>
                <span><strong>Reported by</strong><br />{web?.reported_by || "—"}{web?.serial ? ` · serial ${web.serial}` : ""}</span>
              </div>
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>API tier</DescriptionListTerm>
            <DescriptionListDescription>
              <div>{RuntimeLabel({ runtime: stats?.runtime })}</div>
              <div className="rr-placement">
                <span>{stats?.placement ? `${stats.placement.name || "—"} · namespace ${stats.placement.namespace || "—"} · node ${stats.placement.node || "—"}` : 'loading…'}</span>
                <span><strong>Reported by</strong><br />{stats?.placement?.reported_by || "—"}{stats?.placement?.serial ? ` · serial ${stats.placement.serial}` : ""}</span>
              </div>
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>Database</DescriptionListTerm>
            <DescriptionListDescription>
              <div data-testid="db-version-detail">
                {stats ? (
                  <Label color="purple" icon={<DatabaseIcon />} isCompact>
                    {dbVersionLabel(stats.db.version)}
                  </Label>
                ) : (
                  <Skeleton width="120px" screenreaderText="Waiting for MariaDB" />
                )}
              </div>
              <span className="rr-muted">
                {stats
                  ? `up ${uptime(stats.db.uptime_seconds)} · ${stats.db.latency_ms.toFixed(2)} ms query · ${stats.db.open_connections} conn`
                  : 'loading…'}
              </span>
            </DescriptionListDescription>
          </DescriptionListGroup>
        </DescriptionList>
      </CardBody>
    </Card>
  );
}
