import {
  Card,
  CardBody,
  CardHeader,
  CardTitle,
  Flex,
  FlexItem,
  Grid,
  GridItem,
  Icon,
  Skeleton,
  Title,
} from '@patternfly/react-core';
import { BoltIcon, ClockIcon, DatabaseIcon, DollarSignIcon, UtensilsIcon } from '@patternfly/react-icons';
import { HourBucket, Stats, money } from '../api';

const HourlyBars = ({ buckets }: { buckets: HourBucket[] }) => {
  const peak = Math.max(1, ...buckets.map((bucket) => bucket.orders));
  return (
    <div className="rr-bars" role="img" aria-label="Orders per hour for the last twelve hours">
      {buckets.map((bucket) => (
        <div key={bucket.hour} className="rr-bars__column" title={`${bucket.hour}: ${bucket.orders} orders`}>
          <div className="rr-bars__value">{bucket.orders}</div>
          <div
            className="rr-bars__bar"
            style={{ height: `${Math.max(4, (bucket.orders / peak) * 100)}%` }}
            data-orders={bucket.orders}
          />
          <div className="rr-bars__label">{bucket.hour.slice(0, 2)}</div>
        </div>
      ))}
    </div>
  );
};

const Metric = ({
  icon,
  label,
  value,
  detail,
  testId,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
  detail?: string;
  testId: string;
}) => (
  <Card isCompact isFullHeight>
    <CardBody>
      <Flex direction={{ default: 'column' }} spaceItems={{ default: 'spaceItemsXs' }}>
        <Flex alignItems={{ default: 'alignItemsCenter' }} spaceItems={{ default: 'spaceItemsXs' }}>
          <FlexItem>
            <Icon size="md">{icon}</Icon>
          </FlexItem>
          <FlexItem>
            <div className="rr-metric__label">{label}</div>
          </FlexItem>
        </Flex>
        <FlexItem>
          <Title headingLevel="h3" size="xl" data-testid={testId}>
            {value}
          </Title>
          {detail && <div className="rr-muted">{detail}</div>}
        </FlexItem>
      </Flex>
    </CardBody>
  </Card>
);

export function OpsStrip({ stats }: { stats: Stats | null }) {
  if (!stats) {
    return (
      <Card isCompact>
        <CardBody>
          <Skeleton width="40%" screenreaderText="Loading galley metrics" />
          <Skeleton width="80%" />
        </CardBody>
      </Card>
    );
  }

  return (
    <Grid hasGutter>
      <GridItem span={12} md={6} lg={3}>
        <Metric
          icon={<DollarSignIcon />}
          label="Revenue today"
          value={money(stats.revenue_cents)}
          detail={`${stats.orders_today} missions · avg ${money(stats.avg_ticket_cents)}`}
          testId="metric-revenue"
        />
      </GridItem>
      <GridItem span={12} md={6} lg={3}>
        <Metric
          icon={<UtensilsIcon />}
          label="In flight"
          value={String(stats.queue_depth)}
          detail="orders not yet served"
          testId="metric-queue"
        />
      </GridItem>
      <GridItem span={12} md={6} lg={3}>
        <Metric
          icon={<ClockIcon />}
          label="Busiest hour"
          value={stats.busiest_hour || '—'}
          detail="by order count today"
          testId="metric-busiest"
        />
      </GridItem>
      <GridItem span={12} md={6} lg={3}>
        <Metric
          icon={<BoltIcon />}
          label="Top seller"
          value={stats.top_sellers[0] ? `${stats.top_sellers[0].qty}×` : '—'}
          detail={stats.top_sellers[0]?.name}
          testId="metric-top-seller"
        />
      </GridItem>

      <GridItem span={12} md={6}>
        <Card isCompact isFullHeight>
          <CardHeader>
            <CardTitle>Orders per hour</CardTitle>
          </CardHeader>
          <CardBody>
            <HourlyBars buckets={stats.hourly} />
          </CardBody>
        </Card>
      </GridItem>
      <GridItem span={12} md={6}>
        <Card isCompact isFullHeight>
          <CardHeader>
            <CardTitle>
              <Flex spaceItems={{ default: 'spaceItemsSm' }} alignItems={{ default: 'alignItemsCenter' }}>
                <FlexItem>
                  <Icon>
                    <DatabaseIcon />
                  </Icon>
                </FlexItem>
                <FlexItem>Best sellers today</FlexItem>
              </Flex>
            </CardTitle>
          </CardHeader>
          <CardBody>
            {stats.top_sellers.length === 0 ? (
              <p className="rr-muted">No orders yet today. The galley is waiting.</p>
            ) : (
              <ol className="rr-leaderboard">
                {stats.top_sellers.map((seller, index) => (
                  <li key={seller.name}>
                    <span className="rr-leaderboard__rank">{index + 1}</span>
                    <span className="rr-leaderboard__name">{seller.name}</span>
                    <span className="rr-leaderboard__qty">{seller.qty} sold</span>
                  </li>
                ))}
              </ol>
            )}
          </CardBody>
        </Card>
      </GridItem>
    </Grid>
  );
}
