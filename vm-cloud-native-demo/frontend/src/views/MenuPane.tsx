import {
  Alert,
  Badge,
  Button,
  Card,
  CardBody,
  CardFooter,
  CardHeader,
  CardTitle,
  Divider,
  EmptyState,
  Flex,
  FlexItem,
  Gallery,
  GalleryItem,
  Icon,
  Label,
  NumberInput,
  SearchInput,
  Skeleton,
  Title,
  Toolbar,
  ToolbarContent,
  ToolbarItem,
} from '@patternfly/react-core';
import { BoltIcon, FireIcon, TimesIcon } from '@patternfly/react-icons';
import { MenuItem, money, spiceLabel } from '../api';

interface MenuPaneProps {
  menu: MenuItem[];
  loading: boolean;
  query: string;
  onQuery: (query: string) => void;
  cart: Record<number, number>;
  onSetQty: (menuItemId: number, qty: number) => void;
  customer: string;
  onCustomer: (customer: string) => void;
  cartTotal: number;
  onSubmit: () => void;
  busy: boolean;
  error: string | null;
  onDismissError: () => void;
}

const stockBadge = (item: MenuItem) => (
  <Badge isRead={item.stock === 0}>
    {item.stock === 0 ? 'sold out' : `${item.stock} left`}
  </Badge>
);

export function MenuPane(props: MenuPaneProps) {
  const { menu, loading, query, onQuery, cart, onSetQty, customer, onCustomer, cartTotal, onSubmit, busy } = props;
  const lines = menu.filter((item) => (cart[item.id] ?? 0) > 0);

  return (
    <>
      <Card className="rr-card">
        <CardHeader>
          <CardTitle>
            <Flex alignItems={{ default: 'alignItemsCenter' }} spaceItems={{ default: 'spaceItemsSm' }}>
              <FlexItem>
                <Icon size="lg">
                  <FireIcon />
                </Icon>
              </FlexItem>
              <FlexItem>Galley menu</FlexItem>
              <FlexItem>
                <Badge isRead>{menu.length} dishes</Badge>
              </FlexItem>
            </Flex>
          </CardTitle>
        </CardHeader>
        <CardBody>
          <Toolbar>
            <ToolbarContent>
              <ToolbarItem className="rr-search">
                <SearchInput
                  aria-label="Search the menu"
                  placeholder="Search the menu: spicy, vegan, pork…"
                  value={query}
                  onChange={(_event, value) => onQuery(value)}
                  onClear={() => onQuery('')}
                />
              </ToolbarItem>
            </ToolbarContent>
          </Toolbar>

          {loading ? (
            <div className="rr-menu">
              {[0, 1, 2, 3].map((key) => (
                <Card key={key} isCompact>
                  <CardBody>
                    <Skeleton width="60%" screenreaderText="Loading menu" />
                    <Skeleton width="90%" />
                    <Skeleton width="40%" />
                  </CardBody>
                </Card>
              ))}
            </div>
          ) : menu.length === 0 ? (
            <EmptyState
              titleText="Nothing matches that search"
              icon={FireIcon}
              headingLevel="h3"
              variant="sm"
            >
              <p>Try “spicy”, “vegan” or clear the search.</p>
            </EmptyState>
          ) : (
            <Gallery hasGutter minWidths={{ default: '240px' }} className="rr-menu" data-testid="galley-menu">
              {menu.map((item) => {
                const quantity = cart[item.id] ?? 0;
                return (
                  <GalleryItem key={item.id}>
                    <Card isCompact isFullHeight className={quantity > 0 ? 'rr-dish rr-dish--selected' : 'rr-dish'}>
                      <CardHeader>
                        <CardTitle>
                          <span className="rr-dish__emoji" aria-hidden="true">
                            {item.emoji}
                          </span>
                          <span className="rr-dish__name">{item.name}</span>
                        </CardTitle>
                      </CardHeader>
                      <CardBody>
                        <p className="rr-muted">{item.description}</p>
                        <Flex spaceItems={{ default: 'spaceItemsXs' }} className="rr-dish__tags">
                          <FlexItem>
                            <Label isCompact color="orange" icon={<BoltIcon />}>
                              {spiceLabel(item.spice)}
                            </Label>
                          </FlexItem>
                          {item.vegan && (
                            <FlexItem>
                              <Label isCompact color="green">
                                vegan
                              </Label>
                            </FlexItem>
                          )}
                        </Flex>
                      </CardBody>
                      <CardFooter>
                        <Flex
                          alignItems={{ default: 'alignItemsCenter' }}
                          justifyContent={{ default: 'justifyContentSpaceBetween' }}
                        >
                          <FlexItem>
                            <strong>{money(item.price_cents)}</strong>
                          </FlexItem>
                          <FlexItem>{stockBadge(item)}</FlexItem>
                          <FlexItem>
                            <Button
                              variant={quantity > 0 ? 'primary' : 'secondary'}
                              size="sm"
                              isDisabled={item.stock === 0}
                              ouiaId={`add-${item.id}`}
                              onClick={() => onSetQty(item.id, quantity + 1)}
                            >
                              {quantity > 0 ? `In tray (${quantity})` : 'Add'}
                            </Button>
                          </FlexItem>
                        </Flex>
                      </CardFooter>
                    </Card>
                  </GalleryItem>
                );
              })}
            </Gallery>
          )}
        </CardBody>
      </Card>

      <Card className="rr-card rr-tray">
        <CardHeader>
          <CardTitle>
            <Flex spaceItems={{ default: 'spaceItemsSm' }} alignItems={{ default: 'alignItemsCenter' }}>
              <FlexItem>
                <Icon size="lg">
                  <BoltIcon />
                </Icon>
              </FlexItem>
              <FlexItem>Tray</FlexItem>
              <FlexItem>
                <Badge isRead>{lines.reduce((sum, item) => sum + (cart[item.id] ?? 0), 0)} items</Badge>
              </FlexItem>
            </Flex>
          </CardTitle>
        </CardHeader>
        <CardBody>
          {props.error && (
            <Alert
              variant="danger"
              isInline
              title={props.error}
              actionClose={<Button variant="plain" aria-label="Dismiss" onClick={props.onDismissError} icon={<TimesIcon />} />}
              className="rr-alert"
            />
          )}
          {lines.length === 0 ? (
            <p className="rr-muted">Nothing on the tray yet. Add a bowl to send a mission to the galley.</p>
          ) : (
            <Flex direction={{ default: 'column' }} spaceItems={{ default: 'spaceItemsSm' }}>
              {lines.map((item) => (
                <Flex
                  key={item.id}
                  alignItems={{ default: 'alignItemsCenter' }}
                  justifyContent={{ default: 'justifyContentSpaceBetween' }}
                >
                  <FlexItem>
                    <span aria-hidden="true">{item.emoji}</span> {item.name}
                  </FlexItem>
                  <FlexItem>
                    <NumberInput
                      value={cart[item.id] ?? 0}
                      min={0}
                      max={Math.min(9, item.stock)}
                      inputAriaLabel={`Quantity for ${item.name}`}
                      inputName={`qty-${item.id}`}
                      widthChars={2}
                      onMinus={() => onSetQty(item.id, Math.max(0, (cart[item.id] ?? 0) - 1))}
                      onPlus={() => onSetQty(item.id, (cart[item.id] ?? 0) + 1)}
                      onChange={(event) => {
                        const parsed = Number((event.target as HTMLInputElement).value);
                        onSetQty(item.id, Number.isFinite(parsed) ? Math.max(0, Math.min(item.stock, parsed)) : 0);
                      }}
                    />
                  </FlexItem>
                  <FlexItem>{money(item.price_cents * (cart[item.id] ?? 0))}</FlexItem>
                </Flex>
              ))}
            </Flex>
          )}
        </CardBody>
        <Divider />
        <CardFooter>
          <Flex direction={{ default: 'column' }} spaceItems={{ default: 'spaceItemsSm' }}>
            <Flex alignItems={{ default: 'alignItemsCenter' }} justifyContent={{ default: 'justifyContentSpaceBetween' }}>
              <FlexItem>
                <label htmlFor="rr-customer" className="rr-label">
                  Crew name
                </label>
                <input
                  id="rr-customer"
                  className="rr-input"
                  value={customer}
                  placeholder="Cadet"
                  maxLength={60}
                  onChange={(event) => onCustomer(event.target.value)}
                />
              </FlexItem>
              <FlexItem>
                <Title headingLevel="h3" size="lg">
                  {money(cartTotal)}
                </Title>
              </FlexItem>
            </Flex>
            <Button
              variant="primary"
              isBlock
              ouiaId="place-order"
              isDisabled={lines.length === 0 || busy}
              isLoading={busy}
              onClick={onSubmit}
            >
              Send to galley
            </Button>
          </Flex>
        </CardFooter>
      </Card>
    </>
  );
}
