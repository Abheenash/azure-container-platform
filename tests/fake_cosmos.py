"""A minimal in-memory stand-in for a Cosmos container.

There is no `moto` for Azure, so rather than mock the SDK call-by-call (which
tests the mock, not the code) this implements the four container methods the app
actually uses, with the same not-found exception type the real SDK raises.
"""
from azure.cosmos import exceptions


class _PageIterator:
    """What `query_items(...).by_page(cursor)` returns: an iterator of pages that
    also carries the continuation token, which is the shape the app reads."""

    def __init__(self, pages, continuation_token):
        self._pages = iter(pages)
        self.continuation_token = continuation_token

    def __iter__(self):
        return self

    def __next__(self):
        return next(self._pages)


class _Query:
    def __init__(self, items, page_size):
        self._items = items
        self._page_size = page_size

    def by_page(self, cursor=None):
        start = int(cursor) if cursor else 0
        page = self._items[start:start + self._page_size]
        nxt = start + self._page_size
        token = str(nxt) if nxt < len(self._items) else None
        return _PageIterator([page], token)


class FakeContainer:
    def __init__(self, unreachable=False):
        self.items = {}
        self.unreachable = unreachable

    def read(self):
        if self.unreachable:
            raise exceptions.ServiceRequestError(message="unreachable")
        return {"id": "notes"}

    def create_item(self, body):
        self.items[body["id"]] = dict(body)
        return dict(body)

    def read_item(self, item, partition_key):
        if item not in self.items:
            raise exceptions.CosmosResourceNotFoundError(message="not found")
        return self.items[item]

    def delete_item(self, item, partition_key):
        if item not in self.items:
            raise exceptions.CosmosResourceNotFoundError(message="not found")
        del self.items[item]

    def query_items(self, query, enable_cross_partition_query, max_item_count):
        return _Query(list(self.items.values()), max_item_count)
