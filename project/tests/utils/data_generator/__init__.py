from tests.utils.data_generator.items import ItemsDataGenerator
from tests.utils.data_generator.users import UsersDataGenerator


class DataGenerator:
    """Facade for test data generators."""

    def __init__(self) -> None:
        self.users = UsersDataGenerator()
        self.items = ItemsDataGenerator()
