db.node.updateMany(
  {},
  {
    $pull: {
      observations: {
        time: {
          $lt: new Date(ISODate().getTime() - 1000 * 3600 * 2)
        }
      }
    }
  },
  {}
);
