import { useState } from 'react';
import {
  Badge,
  Button,
  Card,
  CardBody,
  CardHeader,
  CardTitle,
  DataList,
  DataListCell,
  DataListItem,
  DataListItemCells,
  DataListItemRow,
  EmptyState,
  Flex,
  FlexItem,
  Icon,
  Label,
  Progress,
  Spinner,
  Title,
  ToggleGroup,
  ToggleGroupItem,
} from '@patternfly/react-core';
import { CheckCircleIcon, RocketIcon, SyncAltIcon } from '@patternfly/react-icons';
import { Order, OrderStatus, advanceLabel, money, nextStatus, statusColor, statusLabel } from '../api';

interface BoardProps {
  orders: Order[];
  loading: boolean;
  live: boolean;
  advancing: number | null;
  onAdvance: (order: Order) => void;
  onRestock: () => void;
  restocking: boolean;
  onReset: () => void;
  resetting: boolean;
}

const filters: Array<{ id: 'all' | OrderStatus; label: string }> = [
  { id: 'all', label: 'All' },
  { id: 'queued', label: 'Queue' },
  { id: 'cooking', label: 'Cooking' },
  { id: 'plating', label: 'Plating' },
  { id: 'served', label: 'Served' },
];

const stageProgress: Record<OrderStatus, number> = { queued: 25, cooking: 60, plating: 85, served: 100 };

export function Board(props: BoardProps) {
  const { orders, loading, live, advancing, onAdvance, onRestock, restocking, onReset, resetting } = props;
  const [filter, setFilter] = useState<'all' | OrderStatus>('all');
  const visible = filter === 'all' ? orders : orders.filter((order) => order.status === filter);
  const active = orders.filter((order) => order.status !== 'served').length;

  return (
    <Card className="rr-card">
      <CardHeader
        actions={{
          actions: (
            <Flex spaceItems={{ default: 'spaceItemsSm' }} alignItems={{ default: 'alignItemsCenter' }}>
              <FlexItem>
                <span data-testid="live-badge">
                  <Badge isRead={!live}>{live ? 'live' : 'reconnecting'}</Badge>
                </span>
              </FlexItem>
              <FlexItem>
                <Button
                  variant="link"
                  size="sm"
                  icon={<SyncAltIcon />}
                  ouiaId="restock"
                  isLoading={restocking}
                  onClick={onRestock}
                >
                  Restock galley
                </Button>
              </FlexItem>
              <FlexItem>
                <Button variant="link" size="sm" isDanger ouiaId="reset" isLoading={resetting} onClick={onReset}>
                  Clear board
                </Button>
              </FlexItem>
            </Flex>
          ),
          hasNoOffset: true,
        }}
      >
        <CardTitle>
          <Flex alignItems={{ default: 'alignItemsCenter' }} spaceItems={{ default: 'spaceItemsSm' }}>
            <FlexItem>
              <Icon size="lg">
                <RocketIcon />
              </Icon>
            </FlexItem>
            <FlexItem>Mission Control</FlexItem>
            <FlexItem>
              <Badge isRead>{active} in flight</Badge>
            </FlexItem>
          </Flex>
        </CardTitle>
      </CardHeader>
      <CardBody>
        <ToggleGroup aria-label="Filter missions" className="rr-filters">
          {filters.map((entry) => {
            const count = entry.id === 'all' ? orders.length : orders.filter((o) => o.status === entry.id).length;
            return (
              <ToggleGroupItem
                key={entry.id}
                text={`${entry.label} (${count})`}
                buttonId={`filter-${entry.id}`}
                isSelected={filter === entry.id}
                onChange={() => setFilter(entry.id)}
              />
            );
          })}
        </ToggleGroup>

        {loading ? (
          <Flex justifyContent={{ default: 'justifyContentCenter' }} className="rr-board-loading">
            <Spinner aria-label="Loading missions" />
          </Flex>
        ) : visible.length === 0 ? (
          <EmptyState
            titleText="No missions on this station"
            icon={RocketIcon}
            headingLevel="h3"
            variant="sm"
          >
            <p>Send a bowl to the galley and it shows up here the moment MariaDB commits it.</p>
          </EmptyState>
        ) : (
          <DataList aria-label="Mission Control orders" isCompact>
            {visible.map((order) => {
              const next = nextStatus(order.status);
              return (
                <DataListItem key={order.id} id={`order-${order.id}`} aria-labelledby={`order-${order.id}-code`}>
                  <DataListItemRow>
                    <DataListItemCells
                      dataListCells={[
                        <DataListCell key="who" width={2}>
                          <span className="rr-order__code" id={`order-${order.id}-code`}>
                            {order.code}
                          </span>
                          <div className="rr-muted">
                            {order.customer} · {money(order.total_cents)}
                          </div>
                        </DataListCell>,
                        <DataListCell key="items" width={3}>
                          <div data-testid={`order-${order.code}-items`}>
                            {order.items.map((line) => `${line.qty}× ${line.name}`).join(', ')}
                          </div>
                        </DataListCell>,
                        <DataListCell key="eta" width={2}>
                          <Progress
                            aria-label={`Mission ${order.code} progress`}
                            value={stageProgress[order.status]}
                            measureLocation="none"
                            size="sm"
                            title={`~${order.eta_minutes} min`}
                          />
                        </DataListCell>,
                        <DataListCell key="status" width={2}>
                          <div data-testid={`order-${order.code}-status`}>
                            <Label color={statusColor(order.status)} icon={<CheckCircleIcon />} isCompact>
                              {statusLabel[order.status]}
                            </Label>
                          </div>
                        </DataListCell>,
                        <DataListCell key="action" width={2} alignRight>
                          {next ? (
                            <Button
                              variant="secondary"
                              size="sm"
                              ouiaId={`advance-${order.code}`}
                              isLoading={advancing === order.id}
                              onClick={() => onAdvance(order)}
                            >
                              {advanceLabel[order.status]}
                            </Button>
                          ) : (
                            <Title headingLevel="h4" size="md" className="rr-muted">
                              delivered
                            </Title>
                          )}
                        </DataListCell>,
                      ]}
                    />
                  </DataListItemRow>
                </DataListItem>
              );
            })}
          </DataList>
        )}
      </CardBody>
    </Card>
  );
}
